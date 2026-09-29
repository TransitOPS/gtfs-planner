defmodule GtfsPlannerWeb.Gtfs.StationReport2Components do
  @moduledoc """
  Function components for the six station report sections.

  Everything here renders from the normalized report model that
  `StationReport2Live` builds once per load. No calculation happens in this
  module: it composes builder output into semantic structure.

  ## Presentation contracts

    * The station's H1 lives in the workspace header (`StationWorkspace`); this
      module renders a print-only copy so a printed report still names its
      station. Six peer H2 sections follow; card and group titles are H3/H4 so
      the outline stays a real hierarchy.
    * Status is always a word plus an icon and a semantic token, never a literal
      palette colour and never colour alone, and it uses the words the
      validation pages use: Problem, Suggestion, Note, Passed. Naming and ID
      conventions are house style rather than GTFS rules, so a failed naming
      check reads as a Suggestion. Accessibility facts come from
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

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1, count_strip: 1]
  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]
  import GtfsPlannerWeb.ResultComponents, only: [tone_badge: 1]

  alias GtfsPlanner.Gtfs.{Pathway, Stop}
  alias GtfsPlanner.Gtfs.StationReport2.Outcome

  # Problems come first, so the sections read in the order a reader would fix
  # them: getting through the station, then where things are, then how complete
  # the details are, then naming, and last what the station contains.
  @sections [
    %{id: "report2-data-quality", label: "Data quality"},
    %{id: "report2-reachability-connectivity", label: "Routes riders can take"},
    %{id: "report2-gps-checks", label: "Stop locations"},
    %{id: "report2-pathway-field-completeness", label: "Pathway details"},
    %{id: "report2-naming-conventions", label: "Names and IDs"},
    %{id: "report2-station-inventory", label: "What's in this station"}
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

  @doc """
  Builds the stable id of the stop link that opens the report's stop drawer.

  The drawer restores focus to the exact control that opened it, so every
  link needs an id the server can name. Ids are unique per disclosure region
  because a stop appears at most once in a check's detail list.
  """
  def stop_link_id(key, stop_id), do: "open-stop-#{key}-#{slug(stop_id)}"

  defp slug(value), do: String.replace(to_string(value), ~r/[^A-Za-z0-9_-]/, "-")

  defp expanded?(nil, _key), do: false
  defp expanded?(set, key), do: MapSet.member?(set, key)

  # -- Severity vocabulary ---------------------------------------------------

  # The word, tone and plural a check outcome reads as. A naming check that
  # fails is a house-style suggestion, not a GTFS problem, so its outcome is
  # mapped before it is displayed or counted.
  defp naming_severity(:fail), do: :warn
  defp naming_severity(status), do: status

  defp severity_word(:pass), do: "Passed"
  defp severity_word(:fail), do: "Problem"
  defp severity_word(:warn), do: "Suggestion"
  defp severity_word(_other), do: "Note"

  defp severity_tone(:pass), do: "success"
  defp severity_tone(:fail), do: "error"
  defp severity_tone(:warn), do: "warning"
  defp severity_tone(_other), do: "info"

  defp with_naming_severity(checks) do
    Enum.map(checks, &%{&1 | status: naming_severity(&1.status)})
  end

  # The report owns this vocabulary; `count_strip/1` owns only the structure.
  defp outcome_items(counts) do
    [
      %{key: "problems", label: "Problems", count: counts.failed, tone: :error},
      %{key: "suggestions", label: "Suggestions", count: counts.warnings, tone: :warning},
      %{key: "notes", label: "Notes", count: counts.info, tone: :info},
      %{key: "passed", label: "Passed", count: counts.passed, tone: :success}
    ]
  end

  # -- Report header ---------------------------------------------------------

  attr :station_name, :string, required: true
  attr :model, :map, default: nil
  slot :inner_block

  @doc "Renders the outcome counts, the honest limit of the checks, and the section index."
  def report_summary(assigns) do
    assigns =
      assigns
      |> assign(:sections, @sections)
      |> assign(:outcome_items, outcome_count_items(assigns[:model]))

    ~H"""
    <div id="report-summary" class="overflow-clip rounded-card border border-subtle bg-white">
      <div class="flex flex-wrap items-start justify-between gap-x-6 gap-y-3 px-5 py-5 sm:px-6">
        <div class="min-w-0">
          <%!-- The workspace header carries the station's name on screen and is
                not printed, so print gets its own title. --%>
          <p class="hidden text-sm text-muted print:block">Pathways report</p>
          <h1 class="hidden break-words font-display text-2xl font-semibold text-strong print:block">
            {@station_name}
          </h1>
          <p class="font-display text-[24px] font-semibold leading-tight tracking-[-0.025em] text-strong">
            What the checks found
          </p>
          <p class="mt-1.5 text-sm text-muted">
            Station structure, data quality, and connectivity checks
          </p>
        </div>
        {render_slot(@inner_block)}
      </div>

      <div class="border-t border-subtle px-5 py-4 sm:px-6">
        <.count_strip id="report-outcome-counts" items={@outcome_items} />
      </div>

      <nav aria-label="Report sections" class="border-t border-subtle px-5 py-2 sm:px-6 print:hidden">
        <ol class="flex flex-wrap gap-x-6">
          <li :for={section <- @sections}>
            <a
              href={"##{section.id}"}
              class={[
                "inline-flex min-h-11 items-center text-sm font-[650] text-action no-underline",
                "hover:text-action-hover hover:underline",
                "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
              ]}
            >
              {section.label}
            </a>
          </li>
        </ol>
      </nav>

      <p class="border-t border-subtle bg-canvas px-5 py-3 text-[13px] text-muted sm:px-6">
        Checks find gaps and contradictions in the data. They can't confirm it matches the station as built.
      </p>
    </div>
    """
  end

  defp outcome_count_items(nil), do: outcome_items(Outcome.counts([]))

  defp outcome_count_items(model) do
    (model.data_quality_items ++
       model.gps_items ++ with_naming_severity(model.naming_convention_checks))
    |> Outcome.counts()
    |> outcome_items()
  end

  # -- Section frame ---------------------------------------------------------

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  slot :counts, doc: "a count strip that sums up the section"
  slot :inner_block, required: true

  # One card per section: a tinted band that names the section and what it
  # asks, then the evidence. The section owns its H2.
  defp report_section(assigns) do
    ~H"""
    <section id={@id} class="scroll-mt-4 overflow-clip rounded-card border border-subtle bg-white">
      <div class="border-b border-subtle bg-canvas px-5 py-4 sm:px-6">
        <h2 class="font-display text-[20px] font-semibold leading-tight tracking-[-0.02em] text-strong">
          {@title}
        </h2>
        <p class="mt-1 text-[13px] text-muted">{@description}</p>
        <div :if={@counts != []} class="mt-3">{render_slot(@counts)}</div>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :title, :string, required: true
  attr :rest, :global
  slot :inner_block

  # What a region says when its data is missing: what is absent, and why nothing
  # appears. It sits inside a section card, so it draws no border of its own.
  defp report_empty(assigns) do
    ~H"""
    <div class="px-5 py-8 text-center sm:px-6" {@rest}>
      <p class="font-bold text-strong">{@title}</p>
      <p :if={@inner_block != []} class="mx-auto mt-1 max-w-[52ch] text-sm text-muted">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end

  # -- Station inventory -----------------------------------------------------

  attr :report, :map, default: nil

  def station_inventory_section(assigns) do
    assigns = assign(assigns, :inventory, compute_inventory(assigns.report))

    ~H"""
    <.report_section
      id="report2-station-inventory"
      title="What's in this station"
      description="Counts of what the station contains. Compare them with the real station."
    >
      <div class="grid gap-6 px-5 py-5 sm:px-6">
        <div>
          <h3 class="text-sm font-bold text-strong">Node inventory by location type</h3>
          <div class="mt-2 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
            <.stat_tile :for={item <- @inventory.node_counts} value={item.count} label={item.label} />
          </div>
        </div>

        <div>
          <h3 class="text-sm font-bold text-strong">Edge inventory by pathway mode</h3>
          <div class="mt-2 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-7">
            <.stat_tile :for={item <- @inventory.edge_counts} value={item.count} label={item.label} />
          </div>
        </div>

        <div>
          <h3 class="text-sm font-bold text-strong">Pathway directionality</h3>
          <div class="mt-2 grid max-w-md grid-cols-2 gap-3">
            <.stat_tile value={@inventory.directionality.bidirectional} label="Bidirectional" />
            <.stat_tile value={@inventory.directionality.unidirectional} label="Unidirectional" />
          </div>
        </div>
      </div>

      <div class="border-t border-subtle">
        <.report_empty
          :if={@inventory.levels == []}
          id="report2-levels-empty"
          title="No levels defined"
        >
          Level count, names, and indices appear here once the station's stops reference level records.
        </.report_empty>

        <div :if={@inventory.levels != []}>
          <h3 class="px-5 pt-4 text-sm font-bold text-strong sm:px-6">
            Level count, names, and indices
          </h3>
          <div class="mt-2">
            <.table_region label="Levels">
              <table class="w-full text-sm">
                <thead class="bg-canvas">
                  <tr class="border-y border-subtle">
                    <.column_header>Level</.column_header>
                    <.column_header>Name</.column_header>
                    <.column_header align="right">Index</.column_header>
                    <.column_header align="right">Nodes</.column_header>
                  </tr>
                </thead>
                <tbody class="divide-y divide-subtle">
                  <tr :for={level <- @inventory.levels}>
                    <td class="break-words px-4 py-2.5 font-mono sm:px-6">{level.level_id}</td>
                    <td class="break-words px-4 py-2.5">{level.level_name || "—"}</td>
                    <td class="px-4 py-2.5 text-right tabular-nums">
                      {format_level_index(level.level_index)}
                    </td>
                    <td class="px-4 py-2.5 text-right font-bold tabular-nums text-strong sm:px-6">
                      {level.node_count}
                    </td>
                  </tr>
                </tbody>
              </table>
            </.table_region>
          </div>
        </div>
      </div>
    </.report_section>
    """
  end

  attr :value, :any, required: true
  attr :label, :string, required: true

  # One prominent figure and what it counts. The caller owns both strings.
  defp stat_tile(assigns) do
    ~H"""
    <div data-role="metric" class="rounded-control border border-subtle px-4 py-3">
      <div
        data-role="metric-value"
        class="font-display text-[28px] font-semibold leading-none tabular-nums text-strong"
      >
        {@value}
      </div>
      <div data-role="metric-label" class="mt-1.5 break-words text-[13px] text-muted">
        {@label}
      </div>
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
      title="Data quality"
      description="Can riders reach every platform, and is each stop filed under the right place? Includes accessibility settings and duplicate IDs."
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
      title="Stop locations"
      description="Does every stop have coordinates, and are they in the right place?"
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
  attr :description, :string, required: true
  attr :counts_id, :string, required: true
  attr :empty_title, :string, required: true
  attr :empty_body, :string, required: true
  attr :items, :list, required: true
  attr :section, :string, required: true
  attr :expanded, :any, required: true

  defp check_section(assigns) do
    assigns = assign(assigns, :count_items, outcome_items(Outcome.counts(assigns.items)))

    ~H"""
    <.report_section id={@id} title={@title} description={@description}>
      <:counts><.count_strip id={@counts_id} items={@count_items} /></:counts>

      <.report_empty :if={@items == []} id={"#{@id}-empty"} title={@empty_title}>
        {@empty_body}
      </.report_empty>

      <div :if={@items != []} class="divide-y divide-subtle">
        <.report_check_row :for={item <- @items} item={item} section={@section} expanded={@expanded} />
      </div>
    </.report_section>
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
    <div class="px-5 py-4 sm:px-6" data-check={@item.id}>
      <div class="flex flex-col gap-3 sm:flex-row sm:gap-5">
        <.check_status_badge status={@item.status} />
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <p class="break-words text-[15px] font-bold text-strong">{@item.label}</p>
            <.check_value item={@item} />
          </div>
          <p class="mt-1 break-words text-sm text-muted">{@item.description}</p>
          <.check_details :if={@item.detail_layout != nil} item={@item} key={@key} open?={@open?} />
        </div>
      </div>
    </div>
    """
  end

  attr :status, :atom,
    required: true,
    doc: "the outcome as displayed: :pass, :fail, :warn or :info"

  # A fixed column so every check's title starts on the same vertical line.
  defp check_status_badge(assigns) do
    ~H"""
    <div class="sm:w-32 sm:shrink-0">
      <.tone_badge
        tone={severity_tone(@status)}
        class="whitespace-nowrap"
        data-status={to_string(@status)}
      >
        {severity_word(@status)}
      </.tone_badge>
    </div>
    """
  end

  attr :item, :map, required: true

  defp check_value(%{item: %{value_format: :count, value: nil}} = assigns) do
    ~H""
  end

  # A count value is always "how many records this check flagged". A bare
  # number on the far edge of the row reads as noise, so the unit is stated;
  # a non-zero count repeats the row's outcome tone so failures are findable
  # in a column of checks without reading every badge.
  defp check_value(%{item: %{value_format: :count, value: 0}} = assigns) do
    ~H"""
    <span class="shrink-0 text-sm tabular-nums text-muted">0 flagged</span>
    """
  end

  defp check_value(%{item: %{value_format: :count}} = assigns) do
    ~H"""
    <span class="shrink-0 text-sm tabular-nums">
      <span class={["font-bold", count_value_tone(@item.status)]}>{@item.value}</span>
      <span class="text-muted">flagged</span>
    </span>
    """
  end

  defp check_value(%{item: %{value_format: :boolean, value: true}} = assigns) do
    ~H"""
    <span class="shrink-0 text-sm font-bold text-success-fg">Yes</span>
    """
  end

  defp check_value(%{item: %{value_format: :boolean, value: false}} = assigns) do
    ~H"""
    <span class="shrink-0 text-sm font-bold text-error-fg">No</span>
    """
  end

  defp check_value(%{item: %{value_format: :text}} = assigns) do
    ~H"""
    <span class="break-words text-sm font-bold text-strong">{@item.value}</span>
    """
  end

  defp check_value(
         %{item: %{value_format: :compound, id: "entrance_to_platform_connectivity"}} = assigns
       ) do
    ~H"""
    <.compound_value
      bad_count={@item.value.unreachable}
      bad_label="unreachable"
      warn_count={@item.value.exit_only}
      warn_label="exit-only"
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

  defp count_value_tone(:fail), do: "text-error-fg"
  defp count_value_tone(:warn), do: "text-warning-fg"
  defp count_value_tone(_other), do: "text-strong"

  attr :bad_count, :integer, required: true
  attr :bad_label, :string, required: true
  attr :warn_count, :integer, default: 0
  attr :warn_label, :string, default: nil
  attr :good_count, :integer, required: true
  attr :good_label, :string, required: true

  defp compound_value(assigns) do
    ~H"""
    <span class="flex flex-wrap items-baseline gap-x-2 text-[13px]">
      <span :if={@bad_count > 0} class="font-bold tabular-nums text-error-fg">
        {@bad_count} {@bad_label}
      </span>
      <span :if={@warn_count > 0} class="font-bold tabular-nums text-warning-fg">
        {@warn_count} {@warn_label}
      </span>
      <span class="tabular-nums text-muted">{@good_count} {@good_label}</span>
    </span>
    """
  end

  attr :item, :map, required: true
  attr :key, :string, required: true
  attr :open?, :boolean, required: true

  defp check_details(%{item: %{detail_layout: :table, details: details}} = assigns)
       when is_list(details) and details != [] do
    ~H"""
    <div class="mt-3 overflow-clip rounded-control border border-subtle">
      <.table_region label={@item.label}>
        <table class="w-full text-sm">
          <thead class="bg-canvas">
            <tr class="border-b border-subtle">
              <.column_header>Type</.column_header>
              <.column_header align="right">Present</.column_header>
              <.column_header align="right">Missing</.column_header>
            </tr>
          </thead>
          <tbody class="divide-y divide-subtle">
            <tr :for={row <- @item.details}>
              <td class="break-words px-4 py-2.5">{row.type_label}</td>
              <td class="px-4 py-2.5 text-right tabular-nums">{row.present}</td>
              <td class={[
                "px-4 py-2.5 text-right tabular-nums",
                row.missing > 0 && "font-bold text-error-fg"
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

  defp check_details(%{item: %{detail_layout: layout, details: details}} = assigns)
       when layout in [:stop_ids, :stop_ids_with_dots] and is_list(details) and details != [] do
    ~H"""
    <div class="mt-2">
      <.check_disclosure_button key={@key} open?={@open?} label={@item.detail_label} />
      <.evidence_list id={detail_region_id(@key)} open?={@open?}>
        <li :for={entry <- @item.details} class="px-4 py-1">
          <.stop_name_link
            opener_id={stop_link_id(@key, entry.id)}
            stop_id={entry.id}
            name={entry.name}
          />
        </li>
      </.evidence_list>
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
      <.evidence_list id={detail_region_id(@key)} open?={@open?}>
        <li :for={entry <- @item.details} class="px-4 py-1">
          <.stop_name_link
            opener_id={stop_link_id(@key, entry.id)}
            stop_id={entry.id}
            name={entry.name}
          />
          <p class="break-words text-[13px] text-muted">{entry.reason}</p>
        </li>
      </.evidence_list>
    </div>
    """
  end

  defp check_details(assigns) do
    ~H""
  end

  attr :id, :string, required: true
  attr :open?, :boolean, required: true
  slot :inner_block, required: true

  # The stops a check flagged, in one inset list. Collapsed on screen, but still
  # in the document and shown in print.
  defp evidence_list(assigns) do
    ~H"""
    <ul
      id={@id}
      class={[
        "mt-2 divide-y divide-subtle overflow-clip rounded-control border border-subtle bg-canvas py-1",
        not @open? && "hidden print:block"
      ]}
    >
      {render_slot(@inner_block)}
    </ul>
    """
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
      class={[
        "group print:hidden -ml-1 inline-flex min-h-11 cursor-pointer items-center gap-1 rounded-control px-1 text-sm font-[650] text-action",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
      ]}
    >
      <.icon
        name={if @open?, do: "hero-chevron-down", else: "hero-chevron-right"}
        class="size-4 shrink-0"
      />
      <span class="break-words text-left underline-offset-2 group-hover:underline">{@label}</span>
    </button>
    """
  end

  attr :opener_id, :string, required: true
  attr :stop_id, :string, required: true
  attr :name, :string, required: true

  defp stop_name_link(assigns) do
    ~H"""
    <span class="flex flex-wrap items-baseline gap-x-2">
      <button
        id={@opener_id}
        type="button"
        phx-click="select_entity"
        phx-value-entity_id={@stop_id}
        phx-value-entity_type="stop"
        phx-value-opener_id={@opener_id}
        title={@stop_id}
        class={[
          "min-h-11 cursor-pointer break-words text-left text-sm font-[650] text-action underline-offset-2",
          "hover:text-action-hover hover:underline",
          "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        ]}
      >
        {@name}
      </button>
      <span :if={@name != @stop_id} class="break-all font-mono text-[13px] text-muted">
        {@stop_id}
      </span>
    </span>
    """
  end

  # -- Naming and ID conventions --------------------------------------------

  attr :checks, :list, required: true
  attr :expanded, :any, required: true, doc: "MapSet of server-owned open disclosure keys"

  def naming_conventions_section(assigns) do
    counts = assigns.checks |> with_naming_severity() |> Outcome.counts()

    count_items = [
      %{key: "suggestions", label: "Suggestions", count: counts.warnings, tone: :warning},
      %{key: "passed", label: "Passed", count: counts.passed, tone: :success}
    ]

    assigns = assign(assigns, :count_items, count_items)

    ~H"""
    <.report_section
      id="report2-naming-conventions"
      title="Names and IDs"
      description="Are stop names and IDs consistent? These are house conventions. GTFS does not require them."
    >
      <:counts><.count_strip id="naming-counts" items={@count_items} /></:counts>

      <.report_empty
        :if={@checks == []}
        id="report2-naming-conventions-empty"
        title="No naming checks ran"
      >
        Naming and ID convention checks appear here once the station has stops to evaluate.
      </.report_empty>

      <div :if={@checks != []} class="divide-y divide-subtle">
        <.naming_check_row :for={check <- @checks} check={check} expanded={@expanded} />
      </div>
    </.report_section>
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
      |> assign(:severity, naming_severity(assigns.check.status))

    ~H"""
    <div class="px-5 py-4 sm:px-6" data-check={@check.id}>
      <div class="flex flex-col gap-3 sm:flex-row sm:gap-5">
        <.check_status_badge status={@severity} />
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <p class="break-words text-[15px] font-bold text-strong">{@check.label}</p>
            <span :if={@check.issue_count == 0} class="shrink-0 text-sm tabular-nums text-muted">
              0 flagged
            </span>
            <span :if={@check.issue_count > 0} class="shrink-0 text-sm tabular-nums">
              <span class={["font-bold", count_value_tone(@severity)]}>
                {@check.issue_count}
              </span>
              <span class="text-muted">flagged</span>
            </span>
          </div>
          <p class="mt-1 break-words text-sm text-muted">{@check.rule}</p>
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
    <div class="rounded-control border border-subtle bg-canvas px-4 py-3">
      <p class="text-sm text-default">{@intro}</p>
      <p :if={@check.id == "naming_prefix_type_mismatch"} class="mt-1 text-[13px] text-muted">
        Expected prefixes by type: entrance/exit entrance_ · boarding area boarding_ · generic node node_
      </p>
      <ul class="mt-2 space-y-1.5">
        <li
          :for={detail <- @check.details}
          class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5 text-sm"
        >
          <span class="break-all font-mono text-[13px] text-strong">{detail.stop_id}</span>
          <span :if={detail.stop_name} class="break-words text-default">
            {detail.stop_name}
          </span>
          <span :if={detail.location_type} class="break-words text-[13px] text-muted">
            location type {detail.location_type} ({Stop.location_type_label(detail.location_type)})
          </span>
          <span :if={detail.expected_prefix} class="text-[13px] text-muted">
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
    <.report_section
      id="report2-reachability-connectivity"
      title="Routes riders can take"
      description="Can riders get from each entrance to each platform, between platforms, and back out? Following pathway directions."
    >
      <.report_empty
        :if={is_nil(@connectivity_summaries)}
        id="connectivity-empty-report"
        title="No connectivity data"
      >
        Reachability appears here once the station snapshot can be evaluated.
      </.report_empty>

      <div :if={@connectivity_summaries} class="divide-y divide-subtle">
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
    </.report_section>
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
    <div id={"connectivity-#{@dimension}"}>
      <div class="flex flex-wrap items-start justify-between gap-3 px-5 py-4 sm:px-6">
        <div class="min-w-0">
          <h3 class="break-words text-base font-bold text-strong">{@summary.title}</h3>
          <p class="mt-0.5 break-words text-sm text-muted">{@summary.description}</p>
        </div>
        <.tone_badge
          tone={dimension_tone(@summary.status)}
          class="shrink-0 whitespace-nowrap"
          data-dimension-status={to_string(@summary.status)}
        >
          {dimension_label(@summary.status)}
        </.tone_badge>
      </div>

      <div class="flex flex-wrap items-center justify-between gap-x-6 gap-y-1 px-5 pb-3 sm:px-6">
        <.count_strip id={"connectivity-#{@dimension}-counts"} items={@count_items} />
        <button
          :if={@summary.summary_rows != []}
          type="button"
          data-report-control
          phx-click="toggle_connectivity_dimension"
          phx-value-dimension={to_string(@dimension)}
          aria-expanded={to_string(@all_expanded)}
          aria-controls={"connectivity-sources-#{@dimension}"}
          class={[
            "group print:hidden inline-flex min-h-11 cursor-pointer items-center gap-1 rounded-control px-1 text-sm font-[650] text-action",
            "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          ]}
        >
          <.icon
            name={if @all_expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
            class="size-4 shrink-0"
          />
          <span class="underline-offset-2 group-hover:underline">
            {if @all_expanded, do: "Hide all routes", else: "Show all routes"}
          </span>
        </button>
      </div>

      <.report_empty
        :if={@summary.summary_rows == []}
        id={"connectivity-empty-#{@dimension}"}
        title={"No #{String.downcase(@summary.source_label)} records to check"}
      >
        Reachability appears here once the station has {String.downcase(@summary.source_label)} records.
      </.report_empty>

      <div
        :if={@summary.summary_rows != []}
        id={"connectivity-sources-#{@dimension}"}
        class="divide-y divide-subtle border-t border-subtle"
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

      <div :if={@summary.alerts != []} class="space-y-2 px-5 pb-4 sm:px-6">
        <.message
          :for={{alert, index} <- Enum.with_index(@summary.alerts)}
          id={"connectivity-#{@dimension}-alert-#{index}"}
          kind={if alert.level == :error, do: "error", else: "warning"}
          role={if alert.level == :error, do: "alert", else: "status"}
          title={alert.text}
        />
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
    <div class="px-5 py-4 sm:px-6">
      <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
        <button
          type="button"
          data-report-control
          phx-click="toggle_connectivity_source"
          phx-value-dimension={to_string(@dimension)}
          phx-value-source_stop_id={@row.source_stop_id}
          aria-expanded={to_string(@expanded)}
          aria-controls={@region_id}
          class={[
            "group print:hidden -ml-1 inline-flex min-h-11 min-w-0 cursor-pointer items-center gap-1 rounded-control px-1 text-left text-sm font-[650] text-action",
            "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
          ]}
        >
          <.icon
            name={if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
            class="size-4 shrink-0"
          />
          <span class="break-words underline-offset-2 group-hover:underline">
            {@row.source_name}
          </span>
        </button>
        <p class="hidden break-words text-sm font-bold text-strong print:block">
          {@row.source_name}
        </p>
        <.reachability_status status={@row.status} />
      </div>

      <dl class="mt-1 space-y-1 text-sm sm:pl-5">
        <div class="flex flex-col gap-x-2 gap-y-0.5 sm:flex-row">
          <dt class="shrink-0 text-muted sm:w-32">Reachable</dt>
          <dd class="min-w-0 break-words">
            {if @row.reachable != [], do: Enum.join(@row.reachable, ", "), else: "None"}
          </dd>
        </div>
        <div class="flex flex-col gap-x-2 gap-y-0.5 sm:flex-row">
          <dt class="shrink-0 text-muted sm:w-32">Unreachable</dt>
          <dd class="min-w-0 break-words">
            {if @row.unreachable != [], do: Enum.join(@row.unreachable, ", "), else: "None"}
          </dd>
        </div>
        <div class="flex flex-col gap-x-2 gap-y-0.5 sm:flex-row">
          <dt class="shrink-0 text-muted sm:w-32">{@source_label} ID</dt>
          <dd class="min-w-0 break-all font-mono text-[13px]">{@row.source_stop_id}</dd>
        </div>
      </dl>

      <div :if={@group} id={@region_id} class={["mt-4", not @expanded && "hidden print:block"]}>
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
    <.tone_badge
      tone={reachability_tone(@status)}
      class="shrink-0 self-start whitespace-nowrap"
      data-reachability={to_string(@status)}
    >
      {reachability_label(@status)}
    </.tone_badge>
    """
  end

  defp reachability_tone(:full), do: "success"
  defp reachability_tone(:partial), do: "warning"
  defp reachability_tone(:exit_only), do: "warning"
  defp reachability_tone(_none), do: "error"

  defp reachability_label(:full), do: "Fully reachable"
  defp reachability_label(:partial), do: "Partially reachable"
  defp reachability_label(:exit_only), do: "Exit only"
  defp reachability_label(_none), do: "Not reachable"

  defp dimension_tone(:passed), do: "success"
  defp dimension_tone(:warning), do: "warning"
  defp dimension_tone(_fail), do: "error"

  defp dimension_label(:passed), do: "Connected"
  defp dimension_label(:warning), do: "Some routes missing"
  defp dimension_label(_fail), do: "Cut off"

  # -- Pathway field completeness -------------------------------------------

  attr :groups, :list, required: true

  def pathway_field_completeness_section(assigns) do
    ~H"""
    <.report_section
      id="report2-pathway-field-completeness"
      title="Pathway details"
      description="Do pathways carry the details trip planners use? Fill rates for optional fields such as length, travel time and stair count."
    >
      <.report_empty
        :if={@groups == []}
        id="report2-pathway-field-completeness-empty"
        title="No pathways to measure"
      >
        Fill rates appear here once the station has pathway records.
      </.report_empty>

      <div :if={@groups != []} class="divide-y divide-subtle">
        <div :for={group <- @groups} class="px-5 py-4 sm:px-6">
          <h3 class="text-sm font-bold text-strong">{group.mode_label}</h3>
          <div class="mt-2 space-y-2">
            <.field_completeness_row :for={field <- group.fields} field={field} />
          </div>
        </div>
      </div>
    </.report_section>
    """
  end

  attr :field, :map, required: true

  # An optional field is never an error, so a low fill rate reads as a
  # suggestion-toned "Missing", not a red "Fail".
  defp field_completeness_row(assigns) do
    ~H"""
    <div class="flex flex-col gap-1 sm:flex-row sm:items-center sm:gap-4">
      <span class="break-words text-sm font-[650] text-strong sm:w-32 sm:shrink-0">
        {@field.label}
      </span>
      <%!-- `flex-1` is applied only from `sm` up: in a column flex container it
           would resolve the basis on the vertical axis and collapse the track. --%>
      <div class="h-2 w-full max-w-xs rounded-full bg-navy-100 sm:flex-1" aria-hidden="true">
        <div
          class={["h-full rounded-full", fill_tone(@field.status)]}
          style={"width: #{@field.percent}%;"}
        >
        </div>
      </div>
      <span class="text-sm tabular-nums sm:w-20 sm:shrink-0 sm:text-right">
        {@field.present} of {@field.total}
      </span>
      <.tone_badge
        tone={fill_badge_tone(@field.status)}
        class="shrink-0 self-start whitespace-nowrap sm:self-auto"
        data-field-status={to_string(@field.status)}
      >
        {fill_word(@field.status)}
      </.tone_badge>
    </div>
    """
  end

  defp fill_tone(:pass), do: "bg-success-line"
  defp fill_tone(_partial_or_missing), do: "bg-warning-line"

  defp fill_badge_tone(:pass), do: "success"
  defp fill_badge_tone(_partial_or_missing), do: "warning"

  defp fill_word(:pass), do: "Complete"
  defp fill_word(:warn), do: "Partial"
  defp fill_word(_none), do: "Missing"

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
      class="overflow-x-auto focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus"
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
        "px-4 py-2 text-[13px] font-[650] text-muted sm:px-6",
        @align == "right" && "text-right",
        @align == "left" && "text-left"
      ]}
    >
      {render_slot(@inner_block)}
    </th>
    """
  end
end
