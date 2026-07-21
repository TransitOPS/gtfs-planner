defmodule GtfsPlannerWeb.Gtfs.StationReport2Components do
  @moduledoc """
  Function components for the six station report sections.

  Everything here renders from the normalized report model that
  `StationReport2Live` builds once per load. No calculation happens in this
  module: it composes builder output into semantic structure.

  ## Presentation contracts

    * One H1 (the station) and six peer H2 sections; card and group titles are
      H3/H4 so the outline stays a real hierarchy.
    * Status is always a word plus a semantic token, never a literal palette
      colour and never colour alone. Badges come from
      `CoreComponents.status_badge/1`; accessibility facts come from
      `TransitPresentation` so their three-state meaning survives.
    * Counts come from `CoreComponents.count_strip/1`. The component owns the
      structure; this module owns every label, tone, and number.
    * Every icon is `<.icon>`; no raw SVG, no emoji.
    * True comparison tables keep a `<table>` inside a labelled, keyboard
      reachable local overflow region. Everything else stacks.
    * Disclosure is server owned: a real `<button>` with `aria-expanded` and
      `aria-controls`, and a region that stays in the document when collapsed so
      printing a freshly loaded report is complete.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.Gtfs.StationReport2ConnectivityComponents

  import GtfsPlannerWeb.CoreComponents,
    only: [icon: 1, status_badge: 1, callout: 1, empty_state: 1, count_strip: 1]

  alias GtfsPlanner.Gtfs.{Pathway, Stop}

  @toc_sections [
    %{
      id: "report2-station-inventory",
      label: "Station Inventory",
      desc:
        "Node counts by location type, edge counts by pathway mode, directionality, and levels."
    },
    %{
      id: "report2-data-quality",
      label: "Data Quality",
      desc:
        "Structural checks for orphaned nodes, duplicate IDs, missing parents, and required children."
    },
    %{
      id: "report2-gps-checks",
      label: "GPS",
      desc: "Coordinate presence, longitude sign consistency, entrance distance, and clustering."
    },
    %{
      id: "report2-naming-conventions",
      label: "Naming & ID Conventions",
      desc:
        "Title case, ID prefix conventions, prefix/type alignment, and auto-generated name detection."
    },
    %{
      id: "report2-reachability-connectivity",
      label: "Reachability & Connectivity",
      desc: "Pathway connectivity between entrances, platforms, and exits."
    },
    %{
      id: "report2-pathway-field-completeness",
      label: "Pathway Field Completeness",
      desc: "Fill rates for optional pathway fields like traversal time, stair count, and slope."
    }
  ]

  @collapsible_detail_layouts [:stop_ids, :stop_ids_with_dots, :stop_ids_with_reasons]

  @doc """
  Returns every disclosure key the report model can open, as a `MapSet`.

  The LiveView owns disclosure state, but the layouts that *have* a disclosure
  are a rendering fact, so the set is derived here and consumed there. Keeping
  one definition means Expand all can never disagree with what is rendered.
  """
  def collapsible_check_keys(model) do
    check_keys =
      Enum.concat([
        collapsible_item_keys("data-quality", model.data_quality_items),
        collapsible_item_keys("gps", model.gps_items),
        for(
          check <- model.naming_convention_checks,
          check.status == :fail,
          do: check_key("naming", check.id)
        )
      ])

    MapSet.new(check_keys)
  end

  defp collapsible_item_keys(section, items) do
    for item <- items,
        item.detail_layout in @collapsible_detail_layouts,
        is_list(item.details),
        item.details != [],
        do: check_key(section, item.id)
  end

  @doc """
  Builds the stable disclosure key for one check within one report section.
  """
  def check_key(section, id), do: "#{section}-#{id}"

  @doc """
  Builds the stable id of the region a disclosure key controls.
  """
  def detail_region_id(key), do: "check-detail-#{key}"

  defp expanded?(nil, _key), do: false
  defp expanded?(set, key), do: MapSet.member?(set, key)

  # -- Report header ---------------------------------------------------------

  attr :station_name, :string, required: true
  attr :model, :map, default: nil
  slot :inner_block

  @doc "Renders the report identity, outcome counts, and section index."
  def report_toc(assigns) do
    assigns =
      assigns
      |> assign(:sections, @toc_sections)
      |> assign(:outcome_items, outcome_count_items(assigns[:model]))

    ~H"""
    <div class="mb-8 space-y-4">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <p class="hidden text-sm text-base-content/70 print:block">Pathways report</p>
          <h1 class="text-2xl font-semibold break-words">{@station_name}</h1>
          <p class="mt-1 text-sm text-base-content/70">
            Station structure, data quality, and connectivity checks
          </p>
        </div>
        {render_slot(@inner_block)}
      </div>

      <.count_strip id="report-outcome-counts" items={@outcome_items} />

      <nav aria-label="Report sections">
        <ol class="space-y-1">
          <li :for={section <- @sections} class="text-sm">
            <a
              href={"##{section.id}"}
              class="font-medium text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
            >
              {section.label}
            </a>
            <span class="text-base-content/70">{" — " <> section.desc}</span>
          </li>
        </ol>
      </nav>
    </div>
    """
  end

  # The report owns this vocabulary; `count_strip/1` owns only the structure.
  defp outcome_count_items(nil), do: outcome_items_for([])

  defp outcome_count_items(model) do
    outcome_items_for(
      Enum.map(
        model.data_quality_items ++ model.gps_items ++ model.naming_convention_checks,
        & &1.status
      )
    )
  end

  defp outcome_items_for(statuses) do
    [
      %{key: "passed", label: "Passed", count: count_status(statuses, :pass), tone: :success},
      %{key: "warnings", label: "Warnings", count: count_status(statuses, :warn), tone: :warning},
      %{key: "failed", label: "Failed", count: count_status(statuses, :fail), tone: :error},
      %{key: "info", label: "Info", count: count_status(statuses, :info), tone: :neutral}
    ]
  end

  defp count_status(statuses, status), do: Enum.count(statuses, &(&1 == status))

  # -- Station inventory -----------------------------------------------------

  attr :report, :map, default: nil

  def station_inventory_section(assigns) do
    assigns = assign(assigns, :inventory, compute_inventory(assigns.report))

    ~H"""
    <section id="report2-station-inventory" class="scroll-mt-4">
      <h2 class="text-xl font-semibold">Station Inventory</h2>

      <div class="mt-3 space-y-4">
        <.inventory_card title="Node inventory by location type">
          <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
            <.stat_card :for={item <- @inventory.node_counts} count={item.count} label={item.label} />
          </div>
        </.inventory_card>

        <.inventory_card title="Edge inventory by pathway mode">
          <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
            <.stat_card :for={item <- @inventory.edge_counts} count={item.count} label={item.label} />
          </div>
        </.inventory_card>

        <.inventory_card title="Pathway directionality">
          <div class="grid max-w-md grid-cols-2 gap-3">
            <.stat_card count={@inventory.directionality.bidirectional} label="Bidirectional" />
            <.stat_card count={@inventory.directionality.unidirectional} label="Unidirectional" />
          </div>
        </.inventory_card>

        <.empty_state
          :if={@inventory.levels == []}
          id="report2-levels-empty"
          title="No levels defined"
        >
          Level count, names, and indices appear here once the station's stops reference level records.
        </.empty_state>

        <div :if={@inventory.levels != []} class="border border-base-300 bg-base-100">
          <h3 class="border-b border-base-300 px-4 py-2 text-sm font-semibold">
            Level count, names, and indices
          </h3>
          <.table_region label="Levels">
            <table class="w-full text-sm">
              <thead>
                <tr class="border-b border-base-300">
                  <.column_header>Level</.column_header>
                  <.column_header>Name</.column_header>
                  <.column_header align="right">Index</.column_header>
                  <.column_header align="right">Nodes</.column_header>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-300">
                <tr :for={level <- @inventory.levels}>
                  <td class="px-3 py-2 font-mono break-words">{level.level_id}</td>
                  <td class="px-3 py-2 break-words">{level.level_name || "—"}</td>
                  <td class="px-3 py-2 text-right tabular-nums">
                    {format_level_index(level.level_index)}
                  </td>
                  <td class="px-3 py-2 text-right font-medium tabular-nums">{level.node_count}</td>
                </tr>
              </tbody>
            </table>
          </.table_region>
        </div>
      </div>
    </section>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp inventory_card(assigns) do
    ~H"""
    <div class="border border-base-300 bg-base-100">
      <h3 class="border-b border-base-300 px-4 py-2 text-sm font-semibold">{@title}</h3>
      <div class="p-4">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :count, :integer, required: true
  attr :label, :string, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="border border-base-300 px-3 py-2">
      <div class="text-xl font-semibold tabular-nums">{@count}</div>
      <p class="mt-0.5 text-xs text-base-content/70 break-words">{@label}</p>
    </div>
    """
  end

  defp compute_inventory(snapshot) do
    all_stops = [snapshot.station | snapshot.child_stops]
    node_count_map = Enum.frequencies_by(all_stops, & &1.location_type)

    node_counts =
      Enum.map(0..4, fn type ->
        %{label: Stop.location_type_label(type), count: Map.get(node_count_map, type, 0)}
      end)

    edge_count_map = Enum.frequencies_by(snapshot.pathways, & &1.pathway_mode)

    edge_counts =
      Enum.map(1..7, fn mode ->
        %{label: Pathway.mode_label(mode), count: Map.get(edge_count_map, mode, 0)}
      end)

    {bi, uni} =
      Enum.reduce(snapshot.pathways, {0, 0}, fn pathway, {bi, uni} ->
        if pathway.is_bidirectional, do: {bi + 1, uni}, else: {bi, uni + 1}
      end)

    levels =
      Enum.map(snapshot.levels, fn %{level: level, stop_count: stop_count} ->
        %{
          level_id: level.level_id,
          level_name: level.level_name,
          level_index: level.level_index,
          node_count: stop_count
        }
      end)

    %{
      node_counts: node_counts,
      edge_counts: edge_counts,
      directionality: %{bidirectional: bi, unidirectional: uni},
      levels: levels
    }
  end

  defp format_level_index(index) when is_float(index) do
    formatted = :erlang.float_to_binary(abs(index), decimals: 1)

    if index < 0 do
      # Use typographic minus (−) not hyphen-minus (-)
      "−" <> formatted
    else
      formatted
    end
  end

  # -- Data quality and GPS --------------------------------------------------

  attr :items, :list, required: true
  attr :section, :string, required: true
  attr :expanded, :any, required: true, doc: "MapSet of server-owned open disclosure keys"

  def data_quality_section(assigns) do
    ~H"""
    <.check_section
      id="report2-data-quality"
      title="Data Quality"
      counts_id="data-quality-counts"
      empty_title="No data quality checks ran"
      empty_body="Structural checks appear here once the station snapshot can be evaluated."
      items={@items}
      section={@section}
      expanded={@expanded}
    />
    """
  end

  attr :items, :list, required: true
  attr :section, :string, required: true
  attr :expanded, :any, required: true, doc: "MapSet of server-owned open disclosure keys"

  def gps_checks_section(assigns) do
    ~H"""
    <.check_section
      id="report2-gps-checks"
      title="GPS"
      counts_id="gps-counts"
      empty_title="No GPS checks ran"
      empty_body="Coordinate checks appear here once the station has stops to evaluate."
      items={@items}
      section={@section}
      expanded={@expanded}
    />
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :counts_id, :string, required: true
  attr :empty_title, :string, required: true
  attr :empty_body, :string, required: true
  attr :items, :list, required: true
  attr :section, :string, required: true
  attr :expanded, :any, required: true

  defp check_section(assigns) do
    assigns =
      assign(assigns, :count_items, outcome_items_for(Enum.map(assigns.items, & &1.status)))

    ~H"""
    <section id={@id} class="scroll-mt-4">
      <h2 class="text-xl font-semibold">{@title}</h2>
      <.count_strip id={@counts_id} items={@count_items} class="mt-2" />

      <.empty_state :if={@items == []} id={"#{@id}-empty"} title={@empty_title} class="mt-3">
        {@empty_body}
      </.empty_state>

      <div :if={@items != []} class="mt-3 border border-base-300 bg-base-100">
        <div class="divide-y divide-base-300">
          <.report_check_row
            :for={item <- @items}
            item={item}
            section={@section}
            expanded={@expanded}
          />
        </div>
      </div>
    </section>
    """
  end

  attr :item, :map, required: true
  attr :section, :string, required: true
  attr :expanded, :any, required: true

  defp report_check_row(assigns) do
    key = check_key(assigns.section, assigns.item.id)

    assigns =
      assigns
      |> assign(:key, key)
      |> assign(:open?, expanded?(assigns.expanded, key))

    ~H"""
    <div class="px-4 py-3" data-check={@item.id}>
      <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:gap-3">
        <.check_status_badge status={@item.status} />
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <p class="text-sm font-medium break-words">{@item.label}</p>
            <.check_value item={@item} />
          </div>
          <p class="mt-0.5 text-xs text-base-content/70 break-words">{@item.description}</p>
          <.check_details :if={@item.detail_layout != nil} item={@item} key={@key} open?={@open?} />
        </div>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp check_status_badge(assigns) do
    ~H"""
    <%!-- Fixed width so every check label starts on the same vertical line. --%>
    <.status_badge
      status={badge_status(@status)}
      label={status_word(@status)}
      class="w-24 shrink-0 self-start"
      data-status={to_string(@status)}
    />
    """
  end

  defp badge_status(:pass), do: :pass
  defp badge_status(:fail), do: :failed
  defp badge_status(:warn), do: :warning
  defp badge_status(_other), do: :info

  defp status_word(:pass), do: "Pass"
  defp status_word(:fail), do: "Fail"
  defp status_word(:warn), do: "Warning"
  defp status_word(_other), do: "Info"

  attr :item, :map, required: true

  defp check_value(%{item: %{value_format: :count, value: nil}} = assigns) do
    ~H""
  end

  defp check_value(%{item: %{value_format: :count}} = assigns) do
    ~H"""
    <span class="shrink-0 text-sm font-medium tabular-nums">{@item.value}</span>
    """
  end

  defp check_value(%{item: %{value_format: :boolean, value: true}} = assigns) do
    ~H"""
    <span class="shrink-0 text-sm font-medium text-success">Yes</span>
    """
  end

  defp check_value(%{item: %{value_format: :boolean, value: false}} = assigns) do
    ~H"""
    <span class="shrink-0 text-sm font-medium text-error">No</span>
    """
  end

  defp check_value(%{item: %{value_format: :text}} = assigns) do
    ~H"""
    <span class="text-sm font-medium break-words">{@item.value}</span>
    """
  end

  defp check_value(
         %{item: %{value_format: :compound, id: "entrance_to_platform_connectivity"}} = assigns
       ) do
    ~H"""
    <.compound_value
      bad_count={@item.value.unreachable}
      bad_label="unreachable"
      good_count={@item.value.reachable}
      good_label="reachable"
    />
    """
  end

  defp check_value(%{item: %{value_format: :compound, id: "platform_interconnection"}} = assigns) do
    ~H"""
    <.compound_value
      bad_count={@item.value.disconnected}
      bad_label="disconnected"
      good_count={@item.value.connected}
      good_label="connected"
    />
    """
  end

  defp check_value(assigns) do
    ~H""
  end

  attr :bad_count, :integer, required: true
  attr :bad_label, :string, required: true
  attr :good_count, :integer, required: true
  attr :good_label, :string, required: true

  defp compound_value(assigns) do
    ~H"""
    <span class="flex flex-wrap items-baseline gap-x-2 text-xs">
      <span :if={@bad_count > 0} class="font-medium text-error tabular-nums">
        {@bad_count} {@bad_label}
      </span>
      <span class="text-base-content/70 tabular-nums">{@good_count} {@good_label}</span>
    </span>
    """
  end

  attr :item, :map, required: true
  attr :key, :string, required: true
  attr :open?, :boolean, required: true

  defp check_details(%{item: %{detail_layout: :table, details: details}} = assigns)
       when is_list(details) and details != [] do
    ~H"""
    <div class="mt-3 border border-base-300">
      <.table_region label={@item.label}>
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b border-base-300">
              <.column_header>Type</.column_header>
              <.column_header align="right">Present</.column_header>
              <.column_header align="right">Missing</.column_header>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300">
            <tr :for={row <- @item.details}>
              <td class="px-3 py-2 break-words">{row.type_label}</td>
              <td class="px-3 py-2 text-right tabular-nums">{row.present}</td>
              <td class={[
                "px-3 py-2 text-right tabular-nums",
                row.missing > 0 && "font-medium text-error"
              ]}>
                {row.missing}
              </td>
            </tr>
          </tbody>
        </table>
      </.table_region>
    </div>
    """
  end

  defp check_details(%{item: %{detail_layout: :stop_ids, details: details}} = assigns)
       when is_list(details) and details != [] do
    ~H"""
    <div class="mt-2">
      <.check_disclosure_button key={@key} open?={@open?} label={@item.detail_label} />
      <ul id={detail_region_id(@key)} class={["mt-2 space-y-1", not @open? && "hidden print:grid"]}>
        <li :for={entry <- @item.details}>
          <.stop_name_link stop_id={entry.id} name={entry.name} />
        </li>
      </ul>
    </div>
    """
  end

  defp check_details(%{item: %{detail_layout: :stop_ids_with_dots, details: details}} = assigns)
       when is_list(details) and details != [] do
    ~H"""
    <div class="mt-2">
      <.check_disclosure_button key={@key} open?={@open?} label={@item.detail_label} />
      <ul
        id={detail_region_id(@key)}
        class={["mt-2 space-y-1 list-disc pl-5", not @open? && "hidden print:grid"]}
      >
        <li :for={entry <- @item.details}>
          <.stop_name_link stop_id={entry.id} name={entry.name} />
        </li>
      </ul>
    </div>
    """
  end

  defp check_details(
         %{item: %{detail_layout: :stop_ids_with_reasons, details: details}} = assigns
       )
       when is_list(details) and details != [] do
    ~H"""
    <div class="mt-2">
      <.check_disclosure_button key={@key} open?={@open?} label={@item.detail_label} />
      <ul id={detail_region_id(@key)} class={["mt-2 space-y-1.5", not @open? && "hidden print:grid"]}>
        <li :for={entry <- @item.details} class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
          <.stop_name_link stop_id={entry.id} name={entry.name} />
          <span class="text-xs text-base-content/70 break-words">{entry.reason}</span>
        </li>
      </ul>
    </div>
    """
  end

  defp check_details(assigns) do
    ~H""
  end

  attr :key, :string, required: true
  attr :open?, :boolean, required: true
  attr :label, :string, required: true

  defp check_disclosure_button(assigns) do
    ~H"""
    <button
      type="button"
      data-report-control
      phx-click="toggle_check_detail"
      phx-value-key={@key}
      aria-expanded={to_string(@open?)}
      aria-controls={detail_region_id(@key)}
      class="print:hidden inline-flex min-h-11 items-center gap-1 text-sm font-medium text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
    >
      <.icon
        name={if @open?, do: "hero-chevron-down", else: "hero-chevron-right"}
        class="size-4 shrink-0"
      />
      <span class="text-left break-words">{@label}</span>
    </button>
    """
  end

  attr :stop_id, :string, required: true
  attr :name, :string, required: true

  defp stop_name_link(assigns) do
    ~H"""
    <span class="inline-flex flex-wrap items-baseline gap-x-2">
      <button
        type="button"
        phx-click="select_entity"
        phx-value-entity_id={@stop_id}
        phx-value-entity_type="stop"
        title={@stop_id}
        class="text-left text-sm font-medium text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 break-words"
      >
        {@name}
      </button>
      <span :if={@name != @stop_id} class="font-mono text-xs text-base-content/70 break-all">
        {@stop_id}
      </span>
    </span>
    """
  end

  # -- Naming and ID conventions --------------------------------------------

  attr :checks, :list, required: true
  attr :expanded, :any, required: true, doc: "MapSet of server-owned open disclosure keys"

  def naming_conventions_section(assigns) do
    statuses = Enum.map(assigns.checks, & &1.status)

    count_items = [
      %{key: "passed", label: "Passed", count: count_status(statuses, :pass), tone: :success},
      %{key: "failed", label: "Failed", count: count_status(statuses, :fail), tone: :error}
    ]

    assigns = assign(assigns, :count_items, count_items)

    ~H"""
    <section id="report2-naming-conventions" class="scroll-mt-4">
      <h2 class="text-xl font-semibold">Naming &amp; ID Conventions</h2>
      <.count_strip id="naming-counts" items={@count_items} class="mt-2" />

      <.empty_state
        :if={@checks == []}
        id="report2-naming-conventions-empty"
        title="No naming checks ran"
        class="mt-3"
      >
        Naming and ID convention checks appear here once the station has stops to evaluate.
      </.empty_state>

      <div :if={@checks != []} class="mt-3 border border-base-300 bg-base-100">
        <div class="divide-y divide-base-300">
          <.naming_check_row :for={check <- @checks} check={check} expanded={@expanded} />
        </div>
      </div>
    </section>
    """
  end

  attr :check, :map, required: true
  attr :expanded, :any, default: nil

  # Naming checks share the check-row recipe used by Data Quality and GPS. A
  # four-column table only ever compared one number, and its disclosure panel
  # could not stay readable inside a narrow scroll region.
  defp naming_check_row(assigns) do
    key = check_key("naming", assigns.check.id)

    assigns =
      assigns
      |> assign(:key, key)
      |> assign(:region_id, detail_region_id(key))
      |> assign(:open?, expanded?(assigns.expanded, key))
      |> assign(:failed?, assigns.check.status == :fail)

    ~H"""
    <div class="px-4 py-3" data-check={@check.id}>
      <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:gap-3">
        <.check_status_badge status={@check.status} />
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <p class="text-sm font-medium break-words">{@check.label}</p>
            <span class="shrink-0 text-sm font-medium tabular-nums">
              {@check.issue_count}
            </span>
          </div>
          <p class="mt-0.5 text-xs text-base-content/70 break-words">{@check.rule}</p>
          <div :if={@failed?} class="mt-2">
            <.check_disclosure_button key={@key} open?={@open?} label="Show affected stops" />
            <div id={@region_id} class={["mt-2", not @open? && "hidden print:block"]}>
              <.naming_violation_panel check={@check} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :check, :map, required: true

  defp naming_violation_panel(assigns) do
    assigns = assign(assigns, :intro, naming_violation_intro(assigns.check.id))

    ~H"""
    <div class="border-l-4 border-error bg-error/10 px-4 py-3">
      <p class="text-sm">{@intro}</p>
      <p :if={@check.id == "naming_prefix_type_mismatch"} class="mt-1 text-xs text-base-content/70">
        Expected prefixes by type — entrance/exit: entrance_ · boarding area: boarding_ · generic node: node_
      </p>
      <ul class="mt-2 space-y-1">
        <li
          :for={detail <- @check.details}
          class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5 text-sm"
        >
          <span class="font-mono break-all">{detail.stop_id}</span>
          <span :if={detail.stop_name} class="text-base-content/80 break-words">
            {detail.stop_name}
          </span>
          <span :if={detail.location_type} class="text-xs text-base-content/70 break-words">
            location type {detail.location_type} ({Stop.location_type_label(detail.location_type)})
          </span>
          <span :if={detail.expected_prefix} class="text-xs text-base-content/70">
            expected prefix {detail.expected_prefix}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  defp naming_violation_intro("naming_title_case"),
    do: "The following stop names do not use title case:"

  defp naming_violation_intro("naming_node_prefix"),
    do: "The following generic nodes do not use the node_ prefix:"

  defp naming_violation_intro("naming_boarding_prefix"),
    do: "The following boarding areas do not use the boarding_ prefix:"

  defp naming_violation_intro("naming_entrance_prefix"),
    do: "The following entrances/exits do not use the entrance_ prefix:"

  defp naming_violation_intro("naming_prefix_type_mismatch"),
    do: "The following stops have a prefix that does not match their location type:"

  defp naming_violation_intro("naming_autogenerated_name"),
    do: "The following stop names appear auto-generated or are not human-readable:"

  defp naming_violation_intro(_id), do: "The following stops did not pass this check:"

  # -- Reachability and connectivity ----------------------------------------

  attr :connectivity_summaries, :map, default: nil
  attr :connectivity_route_details, :map, default: %{}
  attr :connectivity_routes, :map, default: %{}
  attr :expanded_sources, :any, default: MapSet.new()
  attr :expanded_route_keys, :any, default: MapSet.new()

  def reachability_connectivity_section(assigns) do
    ~H"""
    <section id="report2-reachability-connectivity" class="scroll-mt-4">
      <h2 class="text-xl font-semibold">Reachability &amp; Connectivity</h2>

      <.empty_state
        :if={is_nil(@connectivity_summaries)}
        id="connectivity-empty-report"
        title="No connectivity data"
        class="mt-3"
      >
        Reachability appears here once the station snapshot can be evaluated.
      </.empty_state>

      <div :if={@connectivity_summaries} class="mt-3 flex flex-col gap-4">
        <.connectivity_dimension_section
          :for={dim <- [:entrance_to_platform, :platform_to_platform, :platform_to_exit]}
          summary={Map.get(@connectivity_summaries, dim)}
          dimension={dim}
          expanded_sources={@expanded_sources}
          route_detail_groups={Map.get(@connectivity_route_details, dim, [])}
          routes={@connectivity_routes}
          expanded_route_keys={@expanded_route_keys}
        />
      </div>
    </section>
    """
  end

  attr :summary, :map, required: true
  attr :dimension, :atom, required: true
  attr :expanded_sources, :any, default: MapSet.new()
  attr :route_detail_groups, :list, default: []
  attr :routes, :map, default: %{}
  attr :expanded_route_keys, :any, default: MapSet.new()

  defp connectivity_dimension_section(assigns) do
    stats = assigns.summary.stats

    count_items = [
      %{key: "sources", label: "Sources", count: stats.source_count, tone: :neutral},
      %{key: "targets", label: "Targets", count: stats.target_count, tone: :neutral},
      %{
        key: "connected_pairs",
        label: "Connected pairs",
        count: stats.connected_pairs,
        tone: :success
      },
      %{
        key: "unreachable_pairs",
        label: "Unreachable pairs",
        count: max(stats.total_pairs - stats.connected_pairs, 0),
        tone: :error
      }
    ]

    all_source_ids = Enum.map(assigns.summary.summary_rows, & &1.source_stop_id)

    all_expanded =
      all_source_ids != [] and
        Enum.all?(all_source_ids, fn sid ->
          MapSet.member?(assigns.expanded_sources, {assigns.dimension, sid})
        end)

    assigns =
      assigns
      |> assign(:count_items, count_items)
      |> assign(
        :route_detail_by_source,
        Map.new(assigns.route_detail_groups, fn group -> {group.source.stop_id, group} end)
      )
      |> assign(:all_expanded, all_expanded)

    ~H"""
    <div id={"connectivity-#{@dimension}"} class="border border-base-300 bg-base-100">
      <div class="flex flex-wrap items-start justify-between gap-3 border-b border-base-300 px-4 py-3">
        <div class="min-w-0">
          <h3 class="text-base font-semibold break-words">{@summary.title}</h3>
          <p class="mt-0.5 text-sm text-base-content/70 break-words">{@summary.description}</p>
        </div>
        <.status_badge
          status={dimension_badge_status(@summary.status)}
          label={dimension_badge_label(@summary.status)}
          class="shrink-0"
          data-dimension-status={to_string(@summary.status)}
        />
      </div>

      <div class="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
        <.count_strip id={"connectivity-#{@dimension}-counts"} items={@count_items} />
        <button
          :if={@summary.summary_rows != []}
          type="button"
          data-report-control
          phx-click="toggle_connectivity_dimension"
          phx-value-dimension={to_string(@dimension)}
          aria-expanded={to_string(@all_expanded)}
          aria-controls={"connectivity-sources-#{@dimension}"}
          class="print:hidden inline-flex min-h-11 items-center gap-1 text-sm font-medium text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
        >
          <.icon
            name={if @all_expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
            class="size-4 shrink-0"
          />
          {if @all_expanded, do: "Hide all routes", else: "Show all routes"}
        </button>
      </div>

      <.empty_state
        :if={@summary.summary_rows == []}
        id={"connectivity-empty-#{@dimension}"}
        title={"No #{String.downcase(@summary.source_label)} records to check"}
        class="mx-4 mb-4 mt-0"
      >
        Reachability appears here once the station has {String.downcase(@summary.source_label)} records.
      </.empty_state>

      <div
        :if={@summary.summary_rows != []}
        id={"connectivity-sources-#{@dimension}"}
        class="divide-y divide-base-300 border-t border-base-300"
      >
        <div
          :for={row <- @summary.summary_rows}
          data-source-row={"#{@dimension}-#{row.source_stop_id}"}
        >
          <.connectivity_source_row
            row={row}
            dimension={@dimension}
            source_label={@summary.source_label}
            expanded={MapSet.member?(@expanded_sources, {@dimension, row.source_stop_id})}
            group={Map.get(@route_detail_by_source, row.source_stop_id)}
            routes={@routes}
            expanded_route_keys={@expanded_route_keys}
          />
        </div>
      </div>

      <div :if={@summary.alerts != []} class="space-y-2 px-4 pb-4">
        <div :for={msg <- @summary.alerts}>
          <.callout kind="error" title={msg} role="alert" />
        </div>
      </div>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :dimension, :atom, required: true
  attr :source_label, :string, required: true
  attr :expanded, :boolean, required: true
  attr :group, :map, default: nil
  attr :routes, :map, default: %{}
  attr :expanded_route_keys, :any, default: MapSet.new()

  defp connectivity_source_row(assigns) do
    assigns =
      assign(
        assigns,
        :region_id,
        "connectivity-detail-#{assigns.dimension}-#{assigns.row.source_stop_id}"
      )

    ~H"""
    <div class="px-4 py-3">
      <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
        <button
          type="button"
          data-report-control
          phx-click="toggle_connectivity_source"
          phx-value-dimension={to_string(@dimension)}
          phx-value-source_stop_id={@row.source_stop_id}
          aria-expanded={to_string(@expanded)}
          aria-controls={@region_id}
          class="print:hidden inline-flex min-h-11 min-w-0 items-center gap-1 text-left text-sm font-medium text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
        >
          <.icon
            name={if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
            class="size-4 shrink-0"
          />
          <span class="break-words">{@row.source_name}</span>
        </button>
        <p class="hidden text-sm font-medium print:block break-words">{@row.source_name}</p>
        <.reachability_status status={@row.status} />
      </div>

      <dl class="mt-2 space-y-1 text-sm sm:pl-5">
        <div class="flex flex-col gap-x-2 gap-y-0.5 sm:flex-row">
          <dt class="shrink-0 text-base-content/70 sm:w-32">Reachable</dt>
          <dd class="min-w-0 break-words">
            {if @row.reachable != [], do: Enum.join(@row.reachable, ", "), else: "None"}
          </dd>
        </div>
        <div class="flex flex-col gap-x-2 gap-y-0.5 sm:flex-row">
          <dt class="shrink-0 text-base-content/70 sm:w-32">Unreachable</dt>
          <dd class="min-w-0 break-words">
            {if @row.unreachable != [], do: Enum.join(@row.unreachable, ", "), else: "None"}
          </dd>
        </div>
        <div class="flex flex-col gap-x-2 gap-y-0.5 sm:flex-row">
          <dt class="shrink-0 text-base-content/70 sm:w-32">{@source_label} ID</dt>
          <dd class="min-w-0 font-mono text-xs break-all">{@row.source_stop_id}</dd>
        </div>
      </dl>

      <div
        :if={@group}
        id={@region_id}
        class={["mt-3", not @expanded && "hidden print:block"]}
      >
        <.source_group_card
          group={@group}
          dimension={@dimension}
          routes={@routes}
          expanded_route_keys={@expanded_route_keys}
        />
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp reachability_status(assigns) do
    ~H"""
    <.status_badge
      status={reachability_badge_status(@status)}
      label={reachability_label(@status)}
      class="shrink-0 self-start"
      data-reachability={to_string(@status)}
    />
    """
  end

  defp reachability_badge_status(:full), do: :pass
  defp reachability_badge_status(:partial), do: :warning
  defp reachability_badge_status(_none), do: :failed

  defp reachability_label(:full), do: "Fully reachable"
  defp reachability_label(:partial), do: "Partially reachable"
  defp reachability_label(_none), do: "Not reachable"

  defp dimension_badge_status(:passed), do: :pass
  defp dimension_badge_status(:warning), do: :warning
  defp dimension_badge_status(_fail), do: :failed

  defp dimension_badge_label(:passed), do: "Passed"
  defp dimension_badge_label(:warning), do: "Warning"
  defp dimension_badge_label(_fail), do: "Fail"

  # -- Pathway field completeness -------------------------------------------

  attr :groups, :list, required: true

  def pathway_field_completeness_section(assigns) do
    ~H"""
    <section id="report2-pathway-field-completeness" class="scroll-mt-4">
      <h2 class="text-xl font-semibold">Pathway Field Completeness</h2>

      <.empty_state
        :if={@groups == []}
        id="report2-pathway-field-completeness-empty"
        title="No pathways to measure"
        class="mt-3"
      >
        Fill rates appear here once the station has pathway records.
      </.empty_state>

      <div
        :if={@groups != []}
        class="mt-3 divide-y divide-base-300 border border-base-300 bg-base-100"
      >
        <div :for={group <- @groups} class="px-4 py-3">
          <h3 class="text-sm font-semibold">{group.mode_label}</h3>
          <div class="mt-2 space-y-2">
            <.field_completeness_row :for={field <- group.fields} field={field} />
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :field, :map, required: true

  defp field_completeness_row(assigns) do
    ~H"""
    <div class="flex flex-col gap-1 sm:flex-row sm:items-center sm:gap-4">
      <span class="text-sm font-medium break-words sm:w-32 sm:shrink-0">{@field.label}</span>
      <%!-- `flex-1` is applied only from `sm` up: in a column flex container it
           would resolve the basis on the vertical axis and collapse the track. --%>
      <div class="h-2 w-full max-w-xs bg-base-300 sm:flex-1" aria-hidden="true">
        <div class="h-full bg-base-content/60" style={"width: #{@field.percent}%;"}></div>
      </div>
      <span class="text-sm tabular-nums sm:w-20 sm:shrink-0 sm:text-right">
        {@field.present} / {@field.total}
      </span>
      <.status_badge
        status={badge_status(@field.status)}
        label={status_word(@field.status)}
        class="shrink-0 self-start sm:self-auto"
        data-field-status={to_string(@field.status)}
      />
    </div>
    """
  end

  # -- Shared table scaffolding ---------------------------------------------

  attr :label, :string, required: true
  slot :inner_block, required: true

  # Wraps a true comparison table in a labelled, keyboard-reachable local
  # overflow region so a narrow viewport scrolls the table, not the page.
  defp table_region(assigns) do
    ~H"""
    <div
      role="region"
      aria-label={@label}
      tabindex="0"
      class="overflow-x-auto focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-inset"
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :align, :string, default: "left", values: ~w(left right)
  slot :inner_block, required: true

  defp column_header(assigns) do
    ~H"""
    <th
      scope="col"
      class={[
        "px-3 py-2 text-xs font-semibold text-base-content/70",
        @align == "right" && "text-right",
        @align == "left" && "text-left"
      ]}
    >
      {render_slot(@inner_block)}
    </th>
    """
  end
end
