defmodule GtfsPlannerWeb.Gtfs.TransferComponents do
  @moduledoc """
  Presentation for the Routes › Transfers page.

  The page shell is one bordered workspace split into the version's general
  rules on the left and the selected connection's context on the right. This
  module renders the list pane's table of general rules, its load failure and
  its first-use state, the context pane before a connection is chosen, and the
  labels and reason text the rules display.

  The states reuse the shared callout and empty state rather than the visual
  reference's own state boxes, so a failed load and an empty list read the same
  way here as they do on Routes. The reference is authority for the composition,
  the column order, the copy and the label hierarchy; the application is
  authority for the components, the theme tokens and the accessibility posture.
  A rule's state is always carried by text as well as color, the min-time column
  is tabular, and every row control is a full-height button.
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
  Renders the list pane's table of general rules.

  The count bar names how many rules the current list holds and the
  one-direction reminder; each row names its two endpoints with the scope the
  rule applies to as subtext, its type, and its minimum time right-aligned in
  tabular figures; a rule that needs attention carries a text badge under its
  From endpoint, so its state never depends on color alone. The footer names
  what a row selection drives, and the pagination moves through 50-row pages.

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
      <div class="flex min-h-12 items-center justify-between gap-4 border-b border-base-300 px-4 py-2 text-sm text-base-content/70">
        <span id="transfers-count" role="status">{@total_count} rules</span>
        <span id="transfers-direction-hint">One direction per rule</span>
      </div>

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

  defp route_short_name(%{route_short_name: name}) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp route_short_name(_route), do: nil

  defp column_sort_state(sort_by, sort_dir, column) when column == sort_by do
    case sort_dir do
      :asc -> "asc"
      :desc -> "desc"
    end
  end

  defp column_sort_state(_sort_by, _sort_dir, _column), do: "none"

  @doc """
  Renders the list pane's first-use state for a version without general rules.

  It differs from the filtered-empty state a later step adds: nothing is hidden
  by a filter here, so the copy explains what a rule is for rather than undoing a
  query. The caller supplies the "Create transfer" action once the editor exists;
  until then the state stands on its own with no control to offer.

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
