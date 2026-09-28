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

  The page lists one of two views of the version. The view chips above the
  toolbar count the whole version's general rules and in-seat records, and the
  in-seat view renders read-only: the table keeps the same columns with a footer
  that says so, the toolbar drops the Needs attention checkbox because in-seat
  rows carry no reasons, a version without in-seat records states where they are
  managed, and the inspector names the record, its rider meaning and the Blocks
  handoff instead of the general inspector's coverage, overlap and action
  controls. Nothing here creates, changes or deletes a type 4/5 row (R1).
  """

  use GtfsPlannerWeb, :html

  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Transfer
  alias LiveSelect.Component, as: LiveSelectComponent

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
  Renders the list pane's two view chips.

  The chips are the page's view switcher: the left one lists the version's
  general rules and the right one its in-seat records, each with the count the
  catalog loaded for the whole version rather than for the current filter, so an
  operator sees what a view holds before switching to it. Because type 4/5 rows
  are authored on Blocks, the in-seat chip says so where the operator chooses
  it.

  The pressed chip states `aria-pressed` and changes both its border and its
  weight, so which view is listed never rests on color alone.

  ## Examples

      <.view_chips view={@view} counts={@catalog.counts} />
  """
  attr :view, :atom, required: true, values: [:general, :in_seat]
  attr :counts, :map, required: true, doc: "the catalog's `counts` for the whole version"

  def view_chips(assigns) do
    ~H"""
    <div
      role="group"
      aria-label="Transfer views"
      class="flex flex-wrap gap-2 border-b border-base-300 px-4 py-3"
    >
      <button
        id="transfers-view-general"
        type="button"
        aria-pressed={to_string(@view == :general)}
        phx-click="switch_view"
        phx-value-view="general"
        class={view_chip_classes(@view == :general)}
      >
        General rules ({@counts.general})
      </button>
      <button
        id="transfers-view-in-seat"
        type="button"
        aria-pressed={to_string(@view == :in_seat)}
        phx-click="switch_view"
        phx-value-view="in_seat"
        class={view_chip_classes(@view == :in_seat)}
      >
        In-seat ({@counts.in_seat}) · managed on Blocks
      </button>
    </div>
    """
  end

  # One chip shape, pressed or not: daisyUI's button with a chip's own border
  # and weight. Both states carry the border and the weight change, so the
  # pressed chip is legible without its color.
  defp view_chip_classes(true) do
    "btn h-auto min-h-11 border-primary bg-primary/10 font-semibold text-primary hover:bg-primary/20"
  end

  defp view_chip_classes(false) do
    "btn h-auto min-h-11 border-control-border bg-base-100 font-medium text-base-content/70 hover:border-primary"
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

  The in-seat view drops the Needs attention checkbox: in-seat rows carry no
  attention reasons, so the control could only ever empty the list. The reference
  shows it there, but the catalog cannot answer it.

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

  attr :in_seat?, :boolean,
    required: true,
    doc: "whether the listed view is the read-only in-seat view"

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
            :if={not @in_seat?}
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

  defp count_label(count, true), do: "#{count} in-seat #{pluralize(count, "record")}"
  defp count_label(count, false), do: "#{count} #{pluralize(count, "rule")}"

  # A checked set replaces the list count with itself, in the reference's words:
  # the operator's next decision is what the count bar's live region says.
  defp selection_count_label(_total_count, checked_count, _in_seat?) when checked_count > 0,
    do: "#{checked_count} selected · this version"

  defp selection_count_label(total_count, _checked_count, in_seat?),
    do: count_label(total_count, in_seat?)

  # The footer names what the list can do with a row: general rows drive the
  # context pane, in-seat rows are read-only here and kept in export.
  defp table_footer(true), do: "Read-only here. All records are retained in export."
  defp table_footer(false), do: "Select a connection to see its map and rider impact."

  # The page count names the same rows the count bar does.
  defp pagination_entity(true), do: "in-seat records"
  defp pagination_entity(false), do: "rules"

  defp stop_filter_options(stops) do
    Enum.map(stops, fn stop -> {stop.name || stop.stop_id, stop.stop_id} end)
  end

  defp route_filter_options(routes) do
    Enum.map(routes, &{route_display_name(&1), &1.route_id})
  end

  # "12 · Riverside", or whichever half the route has, or its bare id.
  defp route_display_name(%{route_id: route_id} = route) do
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
  rows. The count names the rows the view holds — general rules or in-seat
  records — as the reference's count bar does.

  Once a rule is checked, the general view's bar also carries the selection's own
  controls: the "Select all shown" checkbox beside the checked count, and "Delete
  selected" on the right. They appear with the selection and leave with it, so an
  empty list and a fresh one read exactly as they did before. Nothing here checks
  or deletes a type 4/5 record (R1), so the in-seat view keeps the count and the
  direction hint and nothing else.

  ## Examples

      <.rule_count total_count={0} in_seat?={false} />
      <.rule_count total_count={12} in_seat?={false} checked_count={2} all_checked?={false} />
  """
  attr :total_count, :integer, required: true

  attr :in_seat?, :boolean,
    required: true,
    doc: "whether the count names in-seat records instead of rules"

  attr :checked_count, :integer, default: 0, doc: "how many of the shown rules are checked"

  attr :all_checked?, :boolean,
    default: false,
    doc: "whether every rule the page shows is checked"

  def rule_count(assigns) do
    ~H"""
    <div class="flex min-h-12 flex-wrap items-center justify-between gap-x-4 gap-y-1 border-b border-base-300 px-4 py-2 text-sm text-base-content/70">
      <div class="flex min-h-11 flex-wrap items-center gap-x-4 gap-y-1">
        <label
          :if={not @in_seat? and @checked_count > 0}
          class="flex min-h-11 cursor-pointer items-center gap-2"
        >
          <input
            type="checkbox"
            id="transfers-select-all"
            checked={@all_checked?}
            phx-click="toggle_check_all"
            class="checkbox"
          />
          <span>Select all shown</span>
        </label>
        <span id="transfers-count" role="status">
          {selection_count_label(@total_count, @checked_count, @in_seat?)}
        </span>
      </div>
      <.button
        :if={not @in_seat? and @checked_count > 0}
        id="transfers-delete-selected"
        type="button"
        variant="danger"
        size="sm"
        class="min-h-11"
        phx-click="delete_selected"
      >
        Delete selected
      </.button>
      <span :if={@checked_count == 0} id="transfers-direction-hint">One direction per rule</span>
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

  The general view leads with the reference's select column: one checkbox per row,
  labelled with the connection it selects, whose checked state is the map the
  caller passes. The in-seat view has no such column, because a type 4/5 record is
  never checked or deleted here (R1).

  The in-seat view lists the same columns read-only: the attention badge cannot
  appear (the catalog annotates in-seat rows with no reasons) and the footer
  says the records are retained in export rather than offering the selection a
  map preview. The reference's own per-row state text and badges have no
  production data yet; the column keeps the reference's "Type" heading.

  ## Examples

      <.rules_table
        rows={@streams.transfers}
        selected_id={@selected_id}
        sort_by={@sort_by}
        sort_dir={@sort_dir}
        page={@page}
        per_page={@per_page}
        total_count={@total_count}
        in_seat?={false}
      />
  """
  attr :rows, :any, required: true, doc: "the `:transfers` stream"
  attr :selected_id, :string, default: nil, doc: "the id of the selected rule"
  attr :sort_by, :atom, required: true, doc: "the sorted column"
  attr :sort_dir, :atom, required: true, doc: "the sort direction, `:asc` or `:desc`"
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total_count, :integer, required: true

  attr :in_seat?, :boolean,
    required: true,
    doc: "whether the rows are the read-only in-seat records"

  attr :checked, :map,
    default: %{},
    doc: "the checked rules, as `%{id => the updated_at the row carried when it was checked}`"

  def rules_table(assigns) do
    ~H"""
    <div>
      <.table id="transfers" rows={@rows} responsive="stack">
        <:col :let={{_dom_id, row}} :if={not @in_seat?} label="Select">
          <div class="flex min-h-11 min-w-11 items-center">
            <input
              type="checkbox"
              id={"transfer-check-#{row.id}"}
              checked={Map.has_key?(@checked, row.id)}
              phx-click="toggle_check"
              phx-value-id={row.id}
              aria-label={"Select #{endpoint_name(row.from)} to #{endpoint_name(row.to)}"}
              class="checkbox"
            />
          </div>
        </:col>
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
              :if={not @in_seat? and row.attention != []}
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
          <%!-- The same wrapper as the From cell, so the stacked layout puts both
          endpoint values on the right rather than beside their label. --%>
          <div>
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
          </div>
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

      <p class="px-4 py-3 text-sm text-base-content/70">{table_footer(@in_seat?)}</p>

      <.pagination
        page={@page}
        per_page={@per_page}
        total={@total_count}
        entity={pagination_entity(@in_seat?)}
      />
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
  Renders the in-seat view's empty state for a version without in-seat records.

  It offers no action, because type 4/5 rows are authored and removed on Blocks:
  there is nothing to create from here. The view chips above it stay reachable,
  so an operator can return to the general rules.

  ## Examples

      <.in_seat_empty />
  """
  def in_seat_empty(assigns) do
    ~H"""
    <div id="transfers-in-seat-empty" class="p-4 sm:p-6">
      <.empty_state title="No in-seat records">
        Stay-on-board connections are managed on Blocks.
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

  The in-seat variant answers the same question for a record this page does not
  own: the eyebrow names the record, the heading and rider meaning come from the
  same labels, and a note says the record is managed on Blocks. The reverse
  control, the station-coverage and overlap callouts, the attention list and the
  related links are general-rule features — an in-seat record has no action here
  (R1).

  ## Examples

      <.inspector
        row={@selected}
        competitors={@competitors}
        compare_open?={@compare_open?}
        version_id={@current_gtfs_version.id}
        in_seat?={false}
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

  attr :in_seat?, :boolean,
    required: true,
    doc: "whether the selected row is a read-only in-seat record"

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
      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
        {inspector_eyebrow(@in_seat?)}
      </p>
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
            :if={not @in_seat? and @row.reverse_id}
            id="transfer-inspector-reverse-inspect"
            type="button"
            variant="quiet"
            size="sm"
            class="min-h-11 text-primary underline underline-offset-4"
            phx-click="inspect_reverse"
          >
            Inspect reverse rule
          </.button>
          <span :if={not @in_seat? and is_nil(@row.reverse_id)}>
            The reverse connection is not changed.
          </span>
        </div>

        <.callout
          :if={@in_seat?}
          id="transfer-inspector-blocks-note"
          kind="info"
          title="Managed on Blocks."
        >
          <p>Changes to stay-on-board records are made there.</p>
        </.callout>

        <.callout
          :if={not @in_seat? and @coverage != []}
          id="transfer-inspector-coverage"
          kind="info"
          title="Station-wide coverage"
        >
          <p :for={endpoint <- @coverage}>{coverage_sentence(endpoint)}</p>
        </.callout>

        <.callout
          :if={not @in_seat? and @competitor_count > 0}
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
          :if={not @in_seat? and @attention != []}
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

        <div :if={not @in_seat?} class="flex flex-wrap gap-4">
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

        <div
          :if={not @in_seat?}
          class="mt-4 flex flex-wrap items-center gap-4 border-t border-base-300 pt-4"
        >
          <.button
            id="transfer-inspector-delete"
            type="button"
            variant="danger"
            size="sm"
            class="min-h-11"
            phx-click="confirm_delete"
          >
            Delete
          </.button>
        </div>
      </div>
    </div>
    """
  end

  # The eyebrow names which of the two views' rows the inspector is showing: an
  # in-seat record is displayed here but owned by Blocks.
  defp inspector_eyebrow(true), do: "In-seat record"
  defp inspector_eyebrow(false), do: "Transfer rule"

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

  @doc """
  Renders the confirmation for deleting the rules the operator selected.

  The dialog lists every rule it will delete — both endpoints with the scope each
  side covers, and the type — and names the version the deletion lands in, so the
  operator confirms named rules rather than a count (R8). A refusal keeps the
  dialog open with its reason, because the rules the click captured no longer
  match what a confirm would delete.

  It is a general-view surface: a type 4/5 record is never listed and never
  deletable here (R1).

  ## Examples

      <.delete_dialog :if={@delete_dialog} dialog={@delete_dialog} version_name="2026-01" />
  """
  attr :dialog, :map, required: true, doc: "the page's pending deletion"

  attr :version_name, :string,
    required: true,
    doc: "the name of the version the listed rules belong to"

  def delete_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="transfer-delete-dialog"
      open={true}
      size="lg"
      title={delete_dialog_title(length(@dialog.rows))}
      confirm_label={delete_dialog_confirm_label(length(@dialog.rows))}
      pending_label="Deleting…"
      on_confirm="apply_delete"
      on_cancel="cancel_delete"
      confirm_variant="danger"
      described_by="transfer-delete-dialog-body"
      return_focus_id={@dialog.return_focus_id}
    >
      <div class="space-y-3">
        <ul class="border border-base-300">
          <li
            :for={row <- @dialog.rows}
            id={"transfer-delete-row-#{row.id}"}
            class="border-b border-base-300 p-3 last:border-b-0"
          >
            <strong class="block">{endpoint_name(row.from)} → {endpoint_name(row.to)}</strong>
            <span class="block text-sm text-base-content/70">
              {selector_label(row.from, :from)} → {selector_label(row.to, :to)} · {type_label(
                row.transfer.transfer_type
              )}
            </span>
          </li>
        </ul>
        <p>
          These exact rules will be removed from {@version_name} and its next export. Stops, routes, and rules outside this selection stay unchanged.
        </p>
        <p>
          Only the listed records will be deleted. In-seat records are excluded. This cannot be undone.
        </p>
        <.callout
          :if={@dialog.error}
          id="transfer-delete-error"
          kind="error"
          title="Nothing was deleted."
        >
          <p>{delete_error_text(@dialog.error)}</p>
        </.callout>
      </div>
    </.confirm_dialog>
    """
  end

  defp delete_dialog_title(1), do: "Delete 1 transfer rule?"
  defp delete_dialog_title(count), do: "Delete #{count} transfer rules?"

  defp delete_dialog_confirm_label(1), do: "Delete 1 rule"
  defp delete_dialog_confirm_label(count), do: "Delete #{count} rules"

  # The three refusals the delete facades answer, under the band's own "Nothing
  # was deleted.": each reason says what happened to the selection the dialog was
  # built from.
  defp delete_error_text(:stale) do
    "One or more rules changed since you selected them. Close this dialog to see the latest rules."
  end

  defp delete_error_text(:not_found) do
    "One or more rules were already removed or can't be deleted here."
  end

  defp delete_error_text(_busy) do
    "The server was busy. Try again."
  end

  # The three scopes the editor offers, in the reference's wording. A scope is the
  # operator's workflow choice; the stored rule keeps only GTFS fields.
  @scope_choices [
    {"stops", "All services at selected stops", "Use a station to cover all its platforms."},
    {"routes", "A route pair at selected stops",
     "Stops still define where the connection happens."},
    {"custom", "Specific trips or mixed selectors",
     "Stops still define where the connection happens."}
  ]

  # One line of help per type, under the type's own label.
  @type_help %{
    0 => "Prefer this connection point.",
    1 => "The departing service waits for this arrival.",
    2 => "Allow enough time to reach the next service.",
    3 => "Do not offer this connection."
  }

  # Where a stop's kind line reads from: a station says how many platforms it
  # covers, a child platform names its station, and anything else is a plain stop.
  @stop_hint_unset "Choose a stop from this version."

  @doc """
  Renders the create-transfer editor in place of the list pane.

  The form is the reference's `create` state: the rule's scope, the two stops
  with a `LiveSelect` search each, the route and trip selects the scope allows,
  the four type choices with their help, the minimum time a minimum-time rule
  requires with its live "m s" readout, the Blocks note, and the footer that
  saves or cancels the draft. The draft's own values are the form's: the LiveView
  clears the dependents of a changed stop or route and reloads the option lists,
  and this component renders whatever the draft holds.

  A `nil` `error` renders nothing; a duplicate names the colliding row's view — a
  general rule can be edited, a type 4/5 record cannot (R1) — and the busy notice
  keeps the draft and offers the retry. Field errors are the form's own, so the
  stop fields carry theirs beside the LiveSelect, which owns the input.

  The editor is a general-view surface: the page renders it for the general view
  only, and its one write is the save.

  ## Examples

      <.editor
        editor={@editor}
        version_name={@current_gtfs_version.name}
        in_seat_path={@in_seat_path}
      />
  """
  attr :editor, :map, required: true, doc: "the page's editor draft"
  attr :version_name, :string, required: true, doc: "the name of the draft's version"

  attr :in_seat_path, :string,
    required: true,
    doc: "the in-seat list of this version, for a collision with a type 4/5 record"

  def editor(assigns) do
    assigns =
      assigns
      |> assign(:from_stop_errors, field_errors(assigns.editor.form, :from_stop_id))
      |> assign(:to_stop_errors, field_errors(assigns.editor.form, :to_stop_id))
      |> assign(:type_errors, field_errors(assigns.editor.form, :transfer_type))
      |> assign(:type_choices, type_choices())
      |> assign(:scope_options, scope_options())
      |> assign(:scope_help, scope_help(assigns.editor.scope))
      |> assign(:draft_type, draft_type(assigns.editor))
      |> assign(:draft_time, draft_min_time(assigns.editor))

    ~H"""
    <div id="transfer-editor" phx-hook="FormErrorFocus" class="p-4 sm:p-6">
      <.button
        id="transfer-back"
        type="button"
        variant="quiet"
        size="sm"
        class="-ml-2 min-h-11 text-primary underline underline-offset-4"
        phx-click="cancel_editor"
      >
        ← Back to transfers
      </.button>

      <h2 class="mt-1 text-xl font-semibold">Create transfer</h2>
      <p class="mt-1 text-sm text-base-content/70">{@version_name} · one direction</p>

      <.callout
        :if={@editor.error}
        id="transfer-form-error"
        kind="error"
        title="Transfer not saved"
      >
        <p :if={in_seat_duplicate?(@editor.error)}>
          A stay-on-board record already uses these stops and trips.
        </p>
        <.link
          :if={in_seat_duplicate?(@editor.error)}
          id="transfer-view-in-seat-link"
          patch={@in_seat_path}
          class="mt-1 inline-block min-h-11 py-1 font-semibold text-primary underline underline-offset-4"
        >
          View in-seat records
        </.link>
        <p :if={general_duplicate?(@editor.error)}>
          A rule already exists for these stops and services. Edit it instead of creating a second rule.
        </p>
        <p :if={@editor.error == :busy}>
          The server couldn't save your changes. Your entries are still here.
        </p>
        <.button
          :if={@editor.error == :busy}
          id="transfer-retry-save"
          type="button"
          variant="secondary"
          size="sm"
          class="mt-2 min-h-11"
          phx-click="retry_save"
        >
          Retry saving
        </.button>
      </.callout>

      <.form
        for={@editor.form}
        id="transfer-form"
        phx-change="editor_change"
        phx-submit="save"
        class="mt-3"
      >
        <div class="border-t border-base-300 pt-4">
          <h3 id="transfer-scope-heading" class="text-sm font-semibold">
            1. Choose who this applies to
          </h3>
          <.input
            id="transfer-scope"
            name="scope"
            type="select"
            label="Rule scope"
            value={scope_value(@editor.scope)}
            options={@scope_options}
            help={@scope_help}
          />
        </div>

        <div class="mt-4 border-t border-base-300 pt-4">
          <h3 class="text-sm font-semibold">2. Set the connection</h3>

          <.connection_side
            side={:from}
            label="A · Arrive at"
            editor={@editor}
            errors={@from_stop_errors}
          />
          <.connection_side
            side={:to}
            label="B · Board at"
            editor={@editor}
            errors={@to_stop_errors}
          />

          <p class="mt-3 text-sm text-base-content/70">
            A → B only. Add the reverse rule separately if riders need it.
          </p>
        </div>

        <fieldset class="mt-4 border-t border-base-300 pt-4">
          <legend class="text-sm font-semibold">3. What should riders know?</legend>

          <label
            :for={{value, label, help} <- @type_choices}
            class="mt-2 flex min-h-11 cursor-pointer items-start gap-3 rounded-box border border-base-300 px-3 py-2 has-[:checked]:border-primary has-[:checked]:bg-primary/5"
          >
            <input
              type="radio"
              id={"transfer-type-#{value}"}
              name={@editor.form[:transfer_type].name}
              value={value}
              checked={@draft_type == value}
              class="radio radio-sm mt-1"
            />
            <span class="min-w-0">
              <span class="block text-sm font-medium">{label}</span>
              <small class="block text-sm text-base-content/70">{help}</small>
            </span>
          </label>

          <p :for={message <- @type_errors} class="mt-1.5 flex items-center gap-2 text-sm text-error">
            <.icon name="hero-exclamation-circle" class="size-5" />{message}
          </p>

          <div :if={@draft_type == 2} class="mt-3">
            <.input
              id="transfer-min-time"
              field={@editor.form[:min_transfer_time]}
              type="number"
              min="0"
              step="1"
              inputmode="numeric"
              label="Minimum time (seconds)"
            />
            <p class="text-sm text-base-content/70">
              <span id="transfer-min-time-readout">
                {min_time_label(@draft_time)} · include walking and a buffer.
              </span>
            </p>
          </div>
        </fieldset>

        <p class="mt-4 text-sm text-base-content/70">
          Looking for a stay-on-board connection? Those are managed on Blocks.
        </p>

        <div class="mt-4 flex flex-wrap items-center gap-3 border-t border-base-300 pt-4">
          <.button id="transfer-save" type="submit" class="min-h-11" phx-disable-with="Saving…">
            Create transfer
          </.button>
          <.button
            id="transfer-cancel"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="cancel_editor"
          >
            Cancel
          </.button>
          <span :if={@editor.dirty?} id="transfer-dirty" class="text-sm text-base-content/70">
            Unsaved changes
          </span>
        </div>
      </.form>
    </div>
    """
  end

  # One side of the connection: the stop search, the kind line of the chosen stop
  # and the route and trip the scope allows. `LiveSelect` owns the text input and
  # the hidden field, so the label points at the input it renders (its id is the
  # form's field id plus `_text_input`), and the field's own error is rendered
  # beside the search rather than by `<.input>`.
  attr :side, :atom, required: true, values: [:from, :to]
  attr :label, :string, required: true, doc: "the reference's side label, such as `A · Arrive at`"
  attr :editor, :map, required: true, doc: "the page's editor draft"
  attr :errors, :list, required: true, doc: "the stop field's inline errors for this side"

  defp connection_side(assigns) do
    side = assigns.side
    field = assigns.editor.form[stop_field(side)]
    stop = stop_option(assigns.editor, side)
    scope = assigns.editor.scope

    assigns =
      assigns
      |> assign(:component_id, "transfer-#{side}-stop")
      |> assign(:input_id, "#{field.id}_text_input")
      |> assign(:field, field)
      |> assign(:stop_options, stop_option_list(stop))
      |> assign(:hint, stop_hint(stop))
      |> assign(:hint_id, "transfer-#{side}-stop-hint")
      |> assign(:error_id, "transfer-#{side}-stop-error")
      |> assign(:scope, scope)
      |> assign(:route_field, assigns.editor.form[route_field(side)])
      |> assign(:route_label, route_field_label(scope, side))
      |> assign(:route_prompt, route_prompt(scope))
      |> assign(:route_options, route_option_list(assigns.editor, side))
      |> assign(:route_chosen?, not is_nil(draft_field(assigns.editor, "#{side}_route_id")))
      |> assign(:trip_field, assigns.editor.form[trip_field(side)])
      |> assign(:trip_label, trip_field_label(side))
      |> assign(:trip_options, trip_option_list(assigns.editor, side))

    ~H"""
    <div class="mt-4">
      <label for={@input_id} class="label mb-1 text-base">{@label}</label>
      <.live_component
        module={LiveSelectComponent}
        id={@component_id}
        field={@field}
        options={@stop_options}
        debounce={200}
        update_min_len={1}
        placeholder="Search stops or stations"
        text_input_class="input input-bordered w-full min-h-11"
        dropdown_class="bg-base-100 border border-base-300 shadow-lg mt-1 text-base-content"
        option_class="px-4 py-2.5 border-b border-base-300 last:border-b-0"
        active_option_class="bg-primary text-primary-content"
        available_option_class="hover:bg-base-200 cursor-pointer"
      >
        <:option :let={option}>
          <span class="font-medium">{option.label}</span>
        </:option>
      </.live_component>
      <p id={@hint_id} class="mt-1.5 text-sm text-base-content/70">{@hint}</p>
      <p :if={@errors != []} id={@error_id} class="mt-1.5 text-sm text-error">
        {Enum.join(@errors, " ")}
      </p>

      <%!-- "All services at selected stops" renders no selector: the stop or
      station is the whole rule. The other two scopes narrow the side to a route,
      and "Specific trips or mixed selectors" narrows it once more to a trip of
      that route. --%>
      <.input
        :if={@scope != :stops}
        id={"transfer-#{@side}-route"}
        field={@route_field}
        type="select"
        label={@route_label}
        prompt={@route_prompt}
        options={@route_options}
      />

      <.input
        :if={@scope == :custom and @route_chosen?}
        id={"transfer-#{@side}-trip"}
        field={@trip_field}
        type="select"
        label={@trip_label}
        prompt="Any trip"
        options={@trip_options}
      />
    </div>
    """
  end

  @doc """
  Renders the context pane's live preview of the draft.

  It answers the same question the inspector answers for a stored rule — the
  type, the connection the draft describes, and what the rule would mean for
  riders — from the draft rather than from a row, so the operator sees the effect
  of a change before saving. The rider meaning is the inspector's own sentence for
  the draft's type; a draft that does not name both stops asks for them instead,
  because a connection is what the preview is about.

  ## Examples

      <.draft_preview editor={@editor} />
  """
  attr :editor, :map, required: true, doc: "the page's editor draft"

  def draft_preview(assigns) do
    assigns =
      assigns
      |> assign(:transfer, draft_transfer(assigns.editor))
      |> assign(:from, draft_endpoint(assigns.editor, :from))
      |> assign(:to, draft_endpoint(assigns.editor, :to))
      |> assign(:both_stops?, both_stops?(assigns.editor))

    ~H"""
    <div id="transfer-draft-preview" class="p-4 sm:p-6">
      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
        Live preview
      </p>
      <h2 class="mt-1 text-xl font-semibold">{type_label(@transfer.transfer_type)}</h2>

      <div class="mt-4 space-y-4">
        <div class="grid grid-cols-[1fr_auto_1fr] items-start gap-3">
          <div class="min-w-0 border-l-4 border-primary pl-3">
            <span class="block text-xs text-base-content/70">Arrive at</span>
            <strong class="block text-sm font-semibold">{@from.name}</strong>
            <span class="block text-xs text-base-content/70">{@from.selector}</span>
          </div>
          <span aria-hidden="true" class="pt-6 text-base-content/50">→</span>
          <div class="min-w-0 border-l-4 border-info pl-3">
            <span class="block text-xs text-base-content/70">Board at</span>
            <strong class="block text-sm font-semibold">{@to.name}</strong>
            <span class="block text-xs text-base-content/70">{@to.selector}</span>
          </div>
        </div>

        <.callout kind="info" title="What this means for riders">
          <.rider_meaning :if={@both_stops?} row={%{transfer: @transfer}} />
          <p :if={not @both_stops?}>Choose both stops to preview the connection.</p>
        </.callout>
      </div>
    </div>
    """
  end

  defp scope_options, do: Enum.map(@scope_choices, fn {value, label, _help} -> {label, value} end)

  # An unknown scope reads as the first choice, which is also the one the LiveView
  # parses an unknown value to, so the select always shows what the draft applies.
  defp scope_choice(scope) do
    Enum.find(@scope_choices, hd(@scope_choices), &(elem(&1, 0) == to_string(scope)))
  end

  defp scope_help(scope) do
    {_value, _label, help} = scope_choice(scope)
    help
  end

  defp scope_value(scope) do
    {value, _label, _help} = scope_choice(scope)
    value
  end

  defp type_choices do
    Enum.map(0..3, &{&1, type_label(&1), Map.fetch!(@type_help, &1)})
  end

  # Field errors reach the form only once the editor has been used: `to_form/2`
  # answers a changeset without an action with no errors at all, and the submit
  # path sets `:insert`, so an untouched draft never opens covered in red.
  defp field_errors(form, field), do: Enum.map(form[field].errors, &translate_error/1)

  # The draft's type and minimum time as the changeset would read them, so the
  # readout and the preview answer the operator's keystrokes rather than the
  # stored row.
  defp draft_type(%{params: params}), do: integer(params["transfer_type"])
  defp draft_min_time(%{params: params}), do: integer(params["min_transfer_time"])

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil

  # The preview reads the draft the way the inspector reads a row: the two
  # endpoints with the scope each side covers, and a transfer struct for the
  # rider meaning's own labels.
  defp draft_transfer(editor) do
    %Transfer{
      from_stop_id: draft_field(editor, "from_stop_id"),
      to_stop_id: draft_field(editor, "to_stop_id"),
      from_route_id: draft_field(editor, "from_route_id"),
      to_route_id: draft_field(editor, "to_route_id"),
      from_trip_id: draft_field(editor, "from_trip_id"),
      to_trip_id: draft_field(editor, "to_trip_id"),
      transfer_type: draft_type(editor),
      min_transfer_time: draft_min_time(editor)
    }
  end

  defp draft_field(editor, key) do
    case editor.params[key] do
      value when is_binary(value) -> blank_to_nil(value)
      _value -> nil
    end
  end

  defp draft_endpoint(editor, side) do
    route_id = draft_field(editor, "#{side}_route_id")
    trip_id = draft_field(editor, "#{side}_trip_id")

    %{
      name: draft_endpoint_name(editor, side),
      selector: selector_label(draft_selector(editor, route_id, trip_id), side)
    }
  end

  defp draft_endpoint_name(editor, side) do
    case {stop_option(editor, side), draft_field(editor, "#{side}_stop_id")} do
      {%{stop_name: name}, _stop_id} when is_binary(name) and name != "" -> name
      {_stop, stop_id} when is_binary(stop_id) -> stop_id
      _neither -> "Choose a stop"
    end
  end

  defp draft_selector(_editor, _route_id, trip_id) when is_binary(trip_id) do
    %{selector: {:trip, trip_id}}
  end

  defp draft_selector(editor, route_id, _trip_id) when is_binary(route_id) do
    %{selector: {:route, route_id}, route: draft_route(editor, route_id)}
  end

  defp draft_selector(_editor, _route_id, _trip_id), do: %{selector: :any}

  # The short name the route select shows, so the preview names the same route.
  defp draft_route(editor, route_id) do
    (editor.options.from_routes ++ editor.options.to_routes)
    |> Enum.find(&(&1.route_id == route_id))
  end

  defp both_stops?(editor) do
    not is_nil(draft_field(editor, "from_stop_id")) and
      not is_nil(draft_field(editor, "to_stop_id"))
  end

  defp stop_field(:from), do: :from_stop_id
  defp stop_field(:to), do: :to_stop_id

  defp route_field(:from), do: :from_route_id
  defp route_field(:to), do: :to_route_id

  defp trip_field(:from), do: :from_trip_id
  defp trip_field(:to), do: :to_trip_id

  # "A route pair at selected stops" requires both routes, so each side's select
  # is what the rule needs; the other two scopes may leave either one empty, and
  # say so beside the label rather than in the prompt alone.
  defp route_field_label(:custom, side), do: "#{side_word(side)} route (optional)"
  defp route_field_label(_scope, side), do: "#{side_word(side)} route"

  defp trip_field_label(side), do: "#{side_word(side)} trip (optional)"

  defp side_word(:from), do: "Arriving"
  defp side_word(:to), do: "Departing"

  # A route the operator must choose reads as a requirement; a route they may
  # leave out offers the empty choice as "Any route".
  defp route_prompt(:custom), do: "Any route"
  defp route_prompt(_scope), do: "Choose route"

  @route_option_notes %{
    not_serving: "doesn't serve this stop",
    inactive: "inactive route",
    missing: "not in this version"
  }

  @trip_option_notes %{
    not_serving: "doesn't stop here",
    other_route: "on another route",
    missing: "not in this version"
  }

  defp route_option_list(editor, :from),
    do: editor.options.from_routes |> Enum.map(&route_option/1)

  defp route_option_list(editor, :to), do: editor.options.to_routes |> Enum.map(&route_option/1)

  # "12 · Riverside", plus why a stored route is no longer one of the stop's own
  # options, so a narrowed draft never shows a route without saying what is odd
  # about it. The value the select submits is the route's own id.
  defp route_option(route) do
    label = with_note(route_display_name(route), @route_option_notes, Map.get(route, :note))
    {label, route.route_id}
  end

  defp trip_option_list(editor, :from), do: editor.options.from_trips |> Enum.map(&trip_option/1)
  defp trip_option_list(editor, :to), do: editor.options.to_trips |> Enum.map(&trip_option/1)

  # "08:15 · Harbor · WKDY": the time the trip serves this side's coverage, its
  # headsign and its service, in the reference's order, with the reason a stored
  # trip is not among the route's own options when there is one (AC-XFER-029). The
  # value the select submits is the trip's own id.
  defp trip_option(trip) do
    base =
      [Map.get(trip, :time), Map.get(trip, :headsign), Map.get(trip, :service_id)]
      |> Enum.map(&blank_to_nil/1)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> trip.trip_id
        parts -> Enum.join(parts, " · ")
      end

    {with_note(base, @trip_option_notes, Map.get(trip, :note)), trip.trip_id}
  end

  defp with_note(label, _notes, nil), do: label
  defp with_note(label, notes, note), do: label <> " — " <> Map.fetch!(notes, note)

  defp stop_option(editor, side) do
    case side do
      :from -> editor.from_stop
      :to -> editor.to_stop
    end
  end

  # The one option a chosen stop renders: `LiveSelect` resolves the field's value
  # to a label from the options it holds, so the draft's own stop travels with the
  # field. Its search replaces this list. A draft without a stop has no option.
  defp stop_option_list(nil), do: []

  defp stop_option_list(%{stop_id: stop_id} = stop) do
    [%{label: stop_label(stop), value: stop_id}]
  end

  @doc """
  Names one stop option for the editor's stop search.

  The stop's name where it has one, and its GTFS id where it does not, so an
  option always names the stop the version holds rather than an editable text.

  ## Examples

      iex> stop_label(%{stop_name: "Central Station", stop_id: "CEN"})
      "Central Station"
  """
  def stop_label(%{stop_name: name, stop_id: stop_id}) do
    case blank_to_nil(name) do
      nil -> stop_id
      name -> name
    end
  end

  defp stop_hint(nil), do: @stop_hint_unset

  defp stop_hint(%{location_type: 1} = stop) do
    case Map.get(stop, :child_count, 0) do
      0 -> "Station"
      count -> "Station · includes #{count} #{pluralize(count, "platform")}"
    end
  end

  defp stop_hint(%{platform_code: code, parent_name: parent})
       when is_binary(code) and is_binary(parent),
       do: "Platform #{code} · #{parent}"

  defp stop_hint(%{parent_name: parent}) when is_binary(parent), do: "Stop · #{parent}"

  defp stop_hint(%{stop_name: name, stop_id: stop_id}) do
    case blank_to_nil(name) do
      nil -> stop_id
      _name -> "Stop in this version."
    end
  end

  # A duplicate names the colliding row's view: a type 4/5 record cannot be
  # edited here (R1), and a collision whose row vanished is offered the general
  # message, because that is where a second rule would be created.
  defp in_seat_duplicate?({:duplicate, %{transfer_type: type}}) when type in 4..5, do: true
  defp in_seat_duplicate?(_error), do: false

  defp general_duplicate?({:duplicate, collision}) when not is_map(collision), do: true
  defp general_duplicate?({:duplicate, %{transfer_type: type}}), do: type in 0..3
  defp general_duplicate?(_error), do: false
end
