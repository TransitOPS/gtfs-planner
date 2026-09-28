defmodule GtfsPlannerWeb.Gtfs.TransferComponents do
  @moduledoc """
  Presentation for the Routes › Transfers page.

  The page shell is one bordered workspace split into the version's general
  rules on the left and the selected connection's context on the right. This
  module renders the list pane's search and filter toolbar, its table of general
  rules, its load failure, first-use and filtered-empty states, the selected
  rule's inspector, the compare view for the rules it competes with, the context
  pane before a connection is chosen, and the labels and reason text the rules
  display.

  The states reuse the shared callout and empty state rather than the visual
  reference's own state boxes, so a failed load and an empty list read the same
  way here as they do on Routes. The reference is authority for the composition,
  the column order, the copy and the label hierarchy; the application is
  authority for the components, the theme tokens and the accessibility posture.
  A rule's state is always carried by text as well as color, the min-time column
  is tabular, and every row control is a full-height button.

  The inspector reads the catalog's selected row and its competitors, so every
  sentence it renders — the rider meaning, the station-coverage count, the
  competing-rule count, the attention reasons and the GTFS values — comes from
  the annotated data rather than from the reference's sample rules. Data terms
  stay in the context and their wording stays here (CR-14).
  """

  use GtfsPlannerWeb, :html

  alias GtfsPlanner.Gtfs.Stop

  @doc """
  Renders the two-pane transfer workspace.

  The list pane is the wider column (about 55%) from `lg` up, with the context
  pane beside it and a divider between them; below `lg` the two panes stack so a
  phone-width viewport never scrolls sideways.

  ## Examples

      <.workspace>
        <:list><.first_use /></:list>
        <:context><.context_empty /></:context>
      </.workspace>
  """
  slot :list, required: true, doc: "the rule list pane"
  slot :context, required: true, doc: "the selected connection's context pane"

  def workspace(assigns) do
    ~H"""
    <div class="mt-6 overflow-hidden rounded-box border border-base-300 bg-base-100 lg:grid lg:grid-cols-[11fr_9fr] lg:items-start">
      <section class="min-w-0 lg:border-r lg:border-base-300" aria-label="Transfer rules">
        {render_slot(@list)}
      </section>
      <section
        class="min-w-0 border-t border-base-300 lg:border-t-0"
        aria-label="Connection preview"
      >
        {render_slot(@context)}
      </section>
    </div>
    """
  end

  @doc """
  Renders the list pane's state when the transfer catalog could not load.

  The copy says what failed and what did not change, because a lost database
  connection leaves every stored rule intact. The retry reloads through the same
  adapter the first load used.

  ## Examples

      <.load_failure />
  """
  def load_failure(assigns) do
    ~H"""
    <div id="transfers-unavailable" class="p-4 sm:p-6">
      <.callout kind="error" title="Transfers couldn’t load">
        Your rules haven’t changed. Try loading this version again.
        <.button
          id="transfers-retry"
          phx-click="retry_load"
          variant="secondary"
          size="sm"
          class="mt-2"
        >
          Retry loading
        </.button>
      </.callout>
    </div>
    """
  end

  @doc """
  Renders the list pane's toolbar: the connection search and the filter
  disclosure.

  The search names what it looks through and patches as the operator types, so a
  term narrows the list without a submit. Beside it, the filters button discloses
  the three selects — stop or station, route and type — which the catalog
  supplies as the current view's own choices, plus the start of an id it has no
  option for. The button counts the applies selects rather than every control, so
  "Filters (2)" means two of the three narrow the list; the Needs attention
  checkbox and Clear filters stay visible while the selects are collapsed, so a
  filter is always removable.

  The disclosure is a control the operator opens, as the reference has it: the
  URL says which filters apply and the button says how many, so a filtered deep
  link is legible before it is opened.

  ## Examples

      <.list_toolbar
        search_form={@search_form}
        filter_form={@filter_form}
        filter_options={@catalog.filter_options}
        filter_count={2}
        filters_open?={@filters_open?}
      />
  """
  attr :search_form, :any, required: true, doc: "the form behind the search field"
  attr :filter_form, :any, required: true, doc: "the form behind the filters"

  attr :filter_options, :map,
    required: true,
    doc: "the catalog's `filter_options` for the listed view"

  attr :filter_count, :integer,
    required: true,
    doc: "how many of the three selects currently apply"

  attr :filters_open?, :boolean, required: true, doc: "whether the filter disclosure is open"

  def list_toolbar(assigns) do
    ~H"""
    <div class="border-b border-base-300 px-4 py-3">
      <div class="flex items-end gap-2">
        <div class="min-w-0 flex-1">
          <.form for={@search_form} id="transfer-search-form" phx-change="search">
            <.input
              field={@search_form[:q]}
              type="search"
              label="Find a connection"
              placeholder="Stop, station, route, trip, or ID"
              phx-debounce="300"
            />
          </.form>
        </div>
        <.button
          id="transfers-filters-toggle"
          type="button"
          variant="secondary"
          phx-click="toggle_filters"
          aria-expanded={to_string(@filters_open?)}
          aria-controls="transfer-filter-fields"
          class="min-h-11"
        >
          {filter_button_label(@filter_count)}
        </.button>
      </div>

      <.form for={@filter_form} id="transfer-filter-form" phx-change="filter">
        <div
          id="transfer-filter-fields"
          hidden={!@filters_open?}
          class="mt-3 grid gap-3 sm:grid-cols-3"
        >
          <.input
            field={@filter_form[:stop]}
            type="select"
            id="transfer-filter-stop"
            label="Stop or station"
            prompt="All locations"
            options={stop_filter_options(@filter_options.stops)}
          />
          <.input
            field={@filter_form[:route]}
            type="select"
            id="transfer-filter-route"
            label="Route"
            prompt="All routes"
            options={route_filter_options(@filter_options.routes)}
          />
          <.input
            field={@filter_form[:type]}
            type="select"
            id="transfer-filter-type"
            label="Type"
            prompt="All types"
            options={type_filter_options(@filter_options.types)}
          />
        </div>

        <div class="mt-3 flex flex-wrap items-center gap-4">
          <.input
            field={@filter_form[:attention]}
            type="checkbox"
            id="transfer-filter-attention"
            label="Needs attention"
          />
          <.button
            id="transfers-clear-filters"
            type="button"
            variant="quiet"
            size="sm"
            class="min-h-11"
            phx-click="clear_filters"
          >
            Clear filters
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  defp filter_button_label(0), do: "Filters"
  defp filter_button_label(count), do: "Filters (#{count})"

  defp stop_filter_options(stops) do
    Enum.map(stops, fn stop -> {stop.name || stop.stop_id, stop.stop_id} end)
  end

  defp route_filter_options(routes) do
    Enum.map(routes, &{route_filter_label(&1), &1.route_id})
  end

  # "12 · Riverside", or whichever half the route has, or its bare id.
  defp route_filter_label(%{route_id: route_id} = route) do
    parts =
      [Map.get(route, :route_short_name), Map.get(route, :route_long_name)]
      |> Enum.map(&blank_to_nil/1)
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> route_id
      _parts -> Enum.join(parts, " · ")
    end
  end

  defp type_filter_options(types), do: Enum.map(types, &{type_label(&1), &1})

  @doc """
  Renders the list pane's count bar: how many rules the current list holds and
  the one-direction reminder.

  It sits between the toolbar and the rows and stays above the filtered-empty
  state, so an emptied list reads "0 rules" instead of losing its count with its
  rows.

  ## Examples

      <.rule_count total_count={0} />
  """
  attr :total_count, :integer, required: true

  def rule_count(assigns) do
    ~H"""
    <div class="flex min-h-12 items-center justify-between gap-4 border-b border-base-300 px-4 py-2 text-sm text-base-content/70">
      <span id="transfers-count" role="status">{@total_count} rules</span>
      <span id="transfers-direction-hint">One direction per rule</span>
    </div>
    """
  end

  @doc """
  Renders the list pane's table of general rules.

  Each row names its two endpoints with the scope the rule applies to as
  subtext, its type, and its minimum time right-aligned in tabular figures; a
  rule that needs attention carries a text badge under its From endpoint, so its
  state never depends on color alone. The footer names what a row selection
  drives, and the pagination moves through 50-row pages.

  The rows are the `:transfers` stream, whose items are `{dom_id, row}` pairs
  with the `transfers-<uuid>` DOM ids the page contract fixes. Selection lives in
  the URL: the caller passes the selected id and the current sort, and a row
  button renders its own highlight from them.

  ## Examples

      <.rules_table
        rows={@streams.transfers}
        selected_id={@selected_id}
        sort_by={@sort_by}
        sort_dir={@sort_dir}
        page={@page}
        per_page={@per_page}
        total_count={@total_count}
      />
  """
  attr :rows, :any, required: true, doc: "the `:transfers` stream"
  attr :selected_id, :string, default: nil, doc: "the id of the selected rule"
  attr :sort_by, :atom, required: true, doc: "the sorted column"
  attr :sort_dir, :atom, required: true, doc: "the sort direction, `:asc` or `:desc`"
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total_count, :integer, required: true

  def rules_table(assigns) do
    ~H"""
    <div>
      <.table id="transfers" rows={@rows} responsive="stack">
        <:col
          :let={{_dom_id, row}}
          label="From"
          sort_key="from"
          sort_event="sort"
          sort={column_sort_state(@sort_by, @sort_dir, :from)}
        >
          <%!-- One wrapper, so the stacked layout keeps the badge under the name
          instead of beside it. --%>
          <div>
            <button
              id={"transfer-select-#{row.id}"}
              type="button"
              phx-click="select_rule"
              phx-value-id={row.id}
              aria-current={row.id == @selected_id && "true"}
              aria-label={"Inspect rule #{endpoint_name(row.from)} to #{endpoint_name(row.to)}"}
              class="block w-full min-h-11 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary"
            >
              <span class="block truncate font-semibold">{endpoint_name(row.from)}</span>
              <span class="block text-xs text-base-content/70">
                {selector_label(row.from, :from)}
              </span>
            </button>
            <span
              :if={row.attention != []}
              id={"transfer-attention-#{row.id}"}
              class="badge badge-warning badge-sm mt-1"
            >
              Needs attention
            </span>
          </div>
        </:col>
        <:col
          :let={{_dom_id, row}}
          label="To"
          sort_key="to"
          sort_event="sort"
          sort={column_sort_state(@sort_by, @sort_dir, :to)}
        >
          <button
            type="button"
            phx-click="select_rule"
            phx-value-id={row.id}
            aria-label={"Inspect rule #{endpoint_name(row.from)} to #{endpoint_name(row.to)}"}
            class="block w-full min-h-11 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary"
          >
            <span class="block truncate font-semibold">{endpoint_name(row.to)}</span>
            <span class="block text-xs text-base-content/70">{selector_label(row.to, :to)}</span>
          </button>
        </:col>
        <:col
          :let={{_dom_id, row}}
          label="Type"
          sort_key="type"
          sort_event="sort"
          sort={column_sort_state(@sort_by, @sort_dir, :type)}
        >
          {type_label(row.transfer.transfer_type)}
        </:col>
        <:col
          :let={{_dom_id, row}}
          label="Min time"
          align="right"
          sort_key="min_time"
          sort_event="sort"
          sort={column_sort_state(@sort_by, @sort_dir, :min_time)}
        >
          <span class="tabular-nums">{min_time_label(row.transfer.min_transfer_time)}</span>
        </:col>
      </.table>

      <p class="px-4 py-3 text-sm text-base-content/70">
        Select a connection to see its map and rider impact.
      </p>

      <.pagination page={@page} per_page={@per_page} total={@total_count} entity="rules" />
    </div>
    """
  end

  @type_labels %{
    0 => "Recommended",
    1 => "Timed connection",
    2 => "Minimum time",
    3 => "Not possible",
    4 => "Stay on board",
    5 => "Alight & reboard"
  }

  @doc """
  Labels a `transfer_type` for display, in the reference's wording.

  ## Examples

      iex> type_label(2)
      "Minimum time"
  """
  def type_label(transfer_type), do: Map.get(@type_labels, transfer_type, "Unknown")

  @doc """
  Formats a minimum transfer time as the reference writes it: whole minutes, with
  the remainder in seconds when there is one, and an em dash when a rule has no
  time stored.

  ## Examples

      iex> min_time_label(150)
      "2m 30s"
  """
  def min_time_label(nil), do: "—"

  def min_time_label(seconds) when is_integer(seconds) do
    case rem(seconds, 60) do
      0 -> "#{div(seconds, 60)}m"
      remainder -> "#{div(seconds, 60)}m #{remainder}s"
    end
  end

  @doc """
  Names a rule's endpoint: the stop or station name, the stored stop id when the
  version no longer contains it, or a sentence when the rule stores no stop at
  all.

  ## Examples

      iex> endpoint_name(%{name: "Central · Bay A", stop_id: "CEN-A"})
      "Central · Bay A"
  """
  def endpoint_name(%{name: name}) when is_binary(name) and name != "", do: name
  def endpoint_name(%{stop_id: stop_id}) when is_binary(stop_id), do: stop_id
  def endpoint_name(_endpoint), do: "Stop not recorded"

  @doc """
  Names the scope a rule applies to on one side of the connection — every arriving
  or departing service at the endpoint, one route (by short name when it has one),
  or one trip.

  ## Examples

      iex> selector_label(%{selector: {:route, "12"}, route: %{route_short_name: "12"}}, :from)
      "Route 12"
  """
  def selector_label(%{selector: :any}, :from), do: "All arriving routes"
  def selector_label(%{selector: :any}, :to), do: "All departing routes"

  def selector_label(%{selector: {:route, route_id}} = endpoint, _side) do
    "Route #{route_short_name(Map.get(endpoint, :route)) || route_id}"
  end

  def selector_label(%{selector: {:trip, trip_id}}, _side), do: "Trip #{trip_id}"

  @doc """
  Writes one attention reason as the text a sighted operator reads (R11).

  The catalog annotates a row with the reasons it needs attention; the text lives
  here so every surface that shows a reason — the list's badge and the
  inspector's reason list — names it the same way.

  ## Examples

      iex> attention_text({:competes, 1})
      "Conflicts with 1 rule of equal priority"
  """
  def attention_text({:competes, count}) do
    "Conflicts with #{count} #{pluralize(count, "rule")} of equal priority"
  end

  def attention_text(:min_time_missing), do: "Minimum time missing"

  def attention_text({:missing_stop, side, stop_id}) do
    "#{side_label(side)} stop #{stop_id} is not in this version"
  end

  def attention_text({:invalid_stop_type, side, stop_id, location_type}) do
    "#{side_label(side)} stop #{stop_id} is #{article(Stop.location_type_label(location_type))}; " <>
      "transfers need a stop, platform or station"
  end

  def attention_text({:missing_route, side, route_id}) do
    "#{side_label(side)} route #{route_id} is not in this version"
  end

  def attention_text({:missing_trip, side, trip_id}) do
    "#{side_label(side)} trip #{trip_id} is not in this version"
  end

  def attention_text({:trip_not_on_route, side, trip_id, route_id}) do
    "#{side_label(side)} trip #{trip_id} is not on route #{route_id}"
  end

  def attention_text({:trip_not_at_stop, side, trip_id, stop_id}) do
    "#{side_label(side)} trip #{trip_id} doesn't stop at #{stop_id}"
  end

  defp side_label(:from), do: "From"
  defp side_label(:to), do: "To"

  defp pluralize(1, noun), do: noun
  defp pluralize(_count, noun), do: noun <> "s"

  defp article(<<first::utf8, _rest::binary>>) when first in ~c"AEIOU", do: "an"
  defp article(_label), do: "a"

  defp route_short_name(route) when is_map(route),
    do: blank_to_nil(Map.get(route, :route_short_name))

  defp route_short_name(_route), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp column_sort_state(sort_by, sort_dir, column) when column == sort_by do
    case sort_dir do
      :asc -> "asc"
      :desc -> "desc"
    end
  end

  defp column_sort_state(_sort_by, _sort_dir, _column), do: "none"

  @doc """
  Renders the list pane's first-use state for a version without general rules.

  It differs from `no_results/1`: nothing is hidden by a filter here, so the copy
  explains what a rule is for rather than undoing a query. The caller supplies
  the "Create transfer" action once the editor exists; until then the state
  stands on its own with no control to offer.

  ## Examples

      <.first_use />
  """
  attr :class, :any, default: nil
  slot :action, doc: "the primary action that creates the version's first rule"

  def first_use(assigns) do
    ~H"""
    <div id="transfers-first-use" class={["p-4 sm:p-6", @class]}>
      <.empty_state title="Make connections clearer">
        Add a rule when riders need a specific connection, extra time, or a different transfer point. Journey planners can infer transfers without these rules.
        <:action :if={@action != []}>
          {render_slot(@action)}
        </:action>
      </.empty_state>
    </div>
    """
  end

  @doc """
  Renders the list pane's filtered-empty state.

  The version has general rules, but the search and filters hide all of them, so
  the state offers the way back — the bare list — instead of asking for a first
  rule. The toolbar above it stays visible, because the search term that emptied
  the list is edited there.

  ## Examples

      <.no_results />
  """
  def no_results(assigns) do
    ~H"""
    <div id="transfers-no-results" class="p-4 sm:p-6">
      <.empty_state title="No matching connections">
        Try another stop, route, or search term.
        <:action>
          <.button
            id="transfers-no-results-clear"
            type="button"
            variant="secondary"
            size="sm"
            class="min-h-11"
            phx-click="clear_filters"
          >
            Clear filters
          </.button>
        </:action>
      </.empty_state>
    </div>
    """
  end

  @doc """
  Renders the context pane's inspector for the selected general rule.

  The pane answers what a rule does: the type, the two endpoints with the scope
  each side covers, what the rule means for riders, which direction it applies
  in, whether a station endpoint makes it station-wide, which equal-priority
  rules compete with it for the same trips, its attention reasons as text, and
  the stored GTFS values behind the summary. Every reason the catalog annotates
  reaches the operator as words, so no state is carried by color alone.

  The direction line reads "Applies in this direction only." because rules are
  one-directional (R7); the reverse link appears only when the catalog found an
  exact mirror of the six key fields in the same view, and the sentence stands in
  its place when there is none. A station endpoint's coverage line counts the
  child platforms the rule covers, so an operator can see why a more specific
  route or trip rule may override it.

  Edit, reverse-create and delete controls are added by later steps; this renders
  the read-only inspector, the compare trigger and the related links.

  ## Examples

      <.inspector
        row={@selected}
        competitors={@competitors}
        compare_open?={@compare_open?}
        version_id={@current_gtfs_version.id}
      />
  """
  attr :row, :map, required: true, doc: "the catalog's selected `row()`"

  attr :competitors, :list,
    required: true,
    doc: "the selected row's competing rows, in the catalog's own order"

  attr :compare_open?, :boolean,
    required: true,
    doc: "whether the compare view is open"

  attr :version_id, :string,
    required: true,
    doc: "the version the stop and route links belong to"

  def inspector(assigns) do
    assigns =
      assigns
      |> assign(:attention, attention_reasons(assigns.row))
      |> assign(:competitor_count, competitor_count(assigns.row))
      |> assign(:coverage, coverage_endpoints(assigns.row))
      |> assign(:detail_lines, detail_lines(assigns.row.transfer))
      |> assign(:from_route_id, route_id(assigns.row.from))
      |> assign(:to_route_id, route_id(assigns.row.to))

    ~H"""
    <div id="transfer-inspector" class="p-4 sm:p-6">
      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/70">Transfer rule</p>
      <h2 class="mt-1 text-xl font-semibold">{type_label(@row.transfer.transfer_type)}</h2>

      <%!-- One spaced column: the shared callout does not accept a `class`, so the
      rhythm between the journey, the callouts and the disclosure lives here. --%>
      <div class="mt-4 space-y-4">
        <div class="grid grid-cols-[1fr_auto_1fr] items-start gap-3">
          <div class="min-w-0 border-l-4 border-primary pl-3">
            <span class="block text-xs text-base-content/70">Arrive at</span>
            <strong class="block text-sm font-semibold">{endpoint_name(@row.from)}</strong>
            <span class="block text-xs text-base-content/70">
              {selector_label(@row.from, :from)}
            </span>
          </div>
          <span aria-hidden="true" class="pt-6 text-base-content/50">→</span>
          <div class="min-w-0 border-l-4 border-info pl-3">
            <span class="block text-xs text-base-content/70">Board at</span>
            <strong class="block text-sm font-semibold">{endpoint_name(@row.to)}</strong>
            <span class="block text-xs text-base-content/70">{selector_label(@row.to, :to)}</span>
          </div>
        </div>

        <.callout kind="info" title="What this means for riders">
          <.rider_meaning row={@row} />
        </.callout>

        <div class="flex flex-wrap items-center gap-2 text-sm text-base-content/70">
          <span>Applies in this direction only.</span>
          <.button
            :if={@row.reverse_id}
            id="transfer-inspector-reverse-inspect"
            type="button"
            variant="quiet"
            size="sm"
            class="min-h-11 text-primary underline underline-offset-4"
            phx-click="inspect_reverse"
          >
            Inspect reverse rule
          </.button>
          <span :if={is_nil(@row.reverse_id)}>The reverse connection is not changed.</span>
        </div>

        <.callout
          :if={@coverage != []}
          id="transfer-inspector-coverage"
          kind="info"
          title="Station-wide coverage"
        >
          <p :for={endpoint <- @coverage}>{coverage_sentence(endpoint)}</p>
        </.callout>

        <.callout
          :if={@competitor_count > 0}
          id="transfer-inspector-overlap"
          kind="warning"
          title="Rules disagree for the same journey"
        >
          <p>{overlap_sentence(@competitor_count)}</p>
          <.button
            id="transfer-inspector-compare"
            type="button"
            variant="secondary"
            size="sm"
            class="mt-2 min-h-11"
            phx-click="open_compare"
          >
            Compare rules
          </.button>
        </.callout>

        <.callout
          :if={@attention != []}
          id="transfer-inspector-attention"
          kind="warning"
          title="Needs attention"
        >
          <ul class="list-disc space-y-1 pl-5">
            <li :for={reason <- @attention}>{attention_text(reason)}</li>
          </ul>
        </.callout>

        <details id="transfer-inspector-details" class="border-t border-base-300 pt-4">
          <summary class="cursor-pointer text-sm font-medium">Rule scope &amp; GTFS details</summary>
          <div class="mt-2 space-y-1 text-sm text-base-content/70">
            <p>{specificity_label(@row)} · type {@row.transfer.transfer_type}</p>
            <p :for={{field, value} <- @detail_lines}>{field}: {value}</p>
            <p class="pt-1">
              Specific trip and route selectors narrow this rule. Equally specific overlapping rules need review.
            </p>
          </div>
        </details>

        <div class="flex flex-wrap gap-4">
          <.link
            :if={@row.from.stop_id}
            id="transfer-inspector-stop-link"
            navigate={~p"/gtfs/#{@version_id}/stops/#{@row.from.stop_id}"}
            class="min-h-11 py-1 text-sm font-semibold text-primary underline underline-offset-4"
          >
            View {endpoint_name(@row.from)}
          </.link>
          <.link
            :if={@from_route_id}
            id="transfer-inspector-route-link-from"
            navigate={~p"/gtfs/#{@version_id}/routes/#{@from_route_id}"}
            class="min-h-11 py-1 text-sm font-semibold text-primary underline underline-offset-4"
          >
            View route {route_label(@row.from)}
          </.link>
          <.link
            :if={@to_route_id}
            id="transfer-inspector-route-link-to"
            navigate={~p"/gtfs/#{@version_id}/routes/#{@to_route_id}"}
            class="min-h-11 py-1 text-sm font-semibold text-primary underline underline-offset-4"
          >
            View route {route_label(@row.to)}
          </.link>
        </div>
      </div>
    </div>
    """
  end

  @rider_meaning_text %{
    0 => "This is a recommended connection point. It does not promise that a vehicle will wait.",
    1 =>
      "The departing vehicle is expected to wait for the arriving service so riders can connect.",
    3 => "Journey planners should not offer this connection.",
    4 => "Riders may stay on the vehicle as it continues on the next trip.",
    5 => "Riders must get off and board again for the next trip."
  }

  @doc """
  Writes what a rule means for riders, in the reference's wording (prototype
  `riderMeaning`).

  A minimum-time rule with a stored time names it, so the sentence carries the
  rule's own number; without one it asks for the time the type requires. The
  sentence is a paragraph of the inspector's rider callout, which supplies the
  surrounding surface.

  ## Examples

      <.rider_meaning row={@row} />
  """
  attr :row, :map, required: true, doc: "the catalog's `row()` to explain"

  def rider_meaning(assigns) do
    transfer = assigns.row.transfer

    assigns =
      assigns
      |> assign(:type, transfer.transfer_type)
      |> assign(:min_time, transfer.min_transfer_time)
      |> assign(:text, Map.get(@rider_meaning_text, transfer.transfer_type, ""))

    ~H"""
    <p :if={@type == 2 and not is_nil(@min_time)}>
      Allow at least <strong>{min_time_label(@min_time)}</strong>
      between arrival and departure, including walking and a buffer.
    </p>
    <p :if={@type == 2 and is_nil(@min_time)}>Set a minimum time for this rule.</p>
    <p :if={@type != 2}>{@text}</p>
    """
  end

  @doc """
  Names how narrow a rule's selectors are, from the rank the catalog computed.

  A rule that names a trip on either side applies to specific trips; a rule that
  names only routes is route-specific; a rule with no selectors is the stop or
  station default that other rules override.

  ## Examples

      iex> specificity_label(%{rank: 4})
      "Route-specific"
  """
  def specificity_label(%{rank: rank}) when rank in 1..3, do: "Trip-specific"
  def specificity_label(%{rank: rank}) when rank in 4..5, do: "Route-specific"
  def specificity_label(_row), do: "Stop / station default"

  @doc """
  Renders the compare view for a rule that competes with equal-priority rules.

  It lists the selected rule and every competitor with the effect each one has —
  its type and minimum time — and the two scopes that make them equally specific,
  so the operator can see why neither takes precedence. Choosing the intended
  behavior is an edit, which later steps add; this dialog is informational and
  closes back to the trigger that opened it.

  ## Examples

      <.compare_dialog :if={@compare_open?} row={@selected} competitors={@competitors} />
  """
  attr :row, :map, required: true, doc: "the selected rule's `row()`"
  attr :competitors, :list, required: true, doc: "the competing rows"

  def compare_dialog(assigns) do
    assigns = assign(assigns, :rules, [assigns.row | assigns.competitors])

    ~H"""
    <.confirm_dialog
      id="transfer-compare-dialog"
      open={true}
      size="lg"
      single_action={true}
      title="Rules that match the same connection"
      confirm_label="Close"
      cancel_label="Close"
      pending_label="Closing…"
      on_confirm="close_compare"
      on_cancel="close_compare"
      described_by="transfer-compare-dialog-body"
      return_focus_id="transfer-inspector-compare"
    >
      <p>
        These rules apply to some of the same trip pairs with equal priority, so neither takes precedence. Choose the intended behavior, then narrow or remove the competing rule.
      </p>
      <div class="mt-3 border border-base-300 p-3">
        <p :for={rule <- @rules} class="py-1">
          <strong class="block">
            {type_label(rule.transfer.transfer_type)} · {min_time_label(
              rule.transfer.min_transfer_time
            )}
          </strong>
          <span class="block">{endpoint_name(rule.from)} → {endpoint_name(rule.to)}</span>
          <span class="block text-base-content/70">
            {selector_label(rule.from, :from)} → {selector_label(rule.to, :to)}
          </span>
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  # The competition reason is the overlap callout's own; every other reason
  # renders in the attention list, as text (R11).
  defp attention_reasons(%{attention: attention}) do
    Enum.reject(attention, &match?({:competes, _}, &1))
  end

  defp competitor_count(%{attention: attention}) do
    Enum.find_value(attention, 0, fn
      {:competes, count} -> count
      _reason -> nil
    end)
  end

  # A rule that names a station covers the station and its child platforms, so a
  # more specific route or trip rule can override it. A station named on both
  # sides is one coverage fact, not two.
  defp coverage_endpoints(row) do
    [row.from, row.to]
    |> Enum.filter(&(&1.child_count > 0))
    |> Enum.uniq_by(& &1.stop_id)
  end

  defp coverage_sentence(endpoint) do
    count = endpoint.child_count

    "#{endpoint_name(endpoint)} includes all #{count} #{pluralize(count, "child platform")}. " <>
      "More specific route or trip rules can override this rule for matching journeys."
  end

  defp overlap_sentence(1) do
    "1 other rule of equal priority matches some of the same trips. " <>
      "Review them before deciding which should apply."
  end

  defp overlap_sentence(count) do
    "#{count} other rules of equal priority match some of the same trips. " <>
      "Review them before deciding which should apply."
  end

  # The eight stored GTFS columns behind the rule, in the reference's order: the
  # two stops always name what the rule stores, the selectors and the minimum
  # time only when the rule has one.
  defp detail_lines(transfer) do
    [
      {"from_stop_id", transfer.from_stop_id || "not set"},
      {"to_stop_id", transfer.to_stop_id || "not set"},
      {"from_route_id", transfer.from_route_id},
      {"to_route_id", transfer.to_route_id},
      {"from_trip_id", transfer.from_trip_id},
      {"to_trip_id", transfer.to_trip_id},
      {"min_transfer_time", min_time_detail(transfer)}
    ]
    |> Enum.reject(fn {_field, value} -> is_nil(value) end)
  end

  defp min_time_detail(%{transfer_type: 2, min_transfer_time: nil}), do: "required seconds"
  defp min_time_detail(%{transfer_type: 2, min_transfer_time: seconds}), do: "#{seconds} seconds"
  defp min_time_detail(_transfer), do: nil

  # A rule's route link needs a route the version still holds: a selector whose
  # route is gone has an attention reason instead of a link to nothing.
  defp route_id(%{route: %{route_id: route_id}}), do: route_id
  defp route_id(_endpoint), do: nil

  defp route_label(%{route: %{route_id: route_id} = route}) do
    route_short_name(route) || route_id
  end

  defp route_label(_endpoint), do: nil

  @doc """
  Renders the context pane before any connection is chosen.

  ## Examples

      <.context_empty />
  """
  def context_empty(assigns) do
    ~H"""
    <div id="transfer-inspector-empty" class="p-4 sm:p-6">
      <h2 class="text-xl font-semibold">A little context goes a long way</h2>
      <p class="mt-3 text-sm text-base-content/70">
        Choose a connection to see where riders arrive, where they board next, and which rule applies.
      </p>
    </div>
    """
  end
end
