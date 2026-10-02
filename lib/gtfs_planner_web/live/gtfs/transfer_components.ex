defmodule GtfsPlannerWeb.Gtfs.TransferComponents do
  @moduledoc """
  Presentation for the Routes › Transfers page, in the TransitOps application
  design system.

  The page is one white card split into the version's rules on the left and the
  selected connection's context on the right. This module renders the left
  pane's view chips, toolbar, count row (or selection bar), table, load failure,
  first-use and filtered-empty states, the right pane's map, the selected rule's
  inspector, the compare and delete dialogs, the create/edit form with its live
  preview, and the labels and sentences the rules display.

  Rules are written in rider and operator words first and GTFS second: a kind is
  "Timed transfer" or "Minimum time", and `transfer_type N` appears only as muted
  detail. Every rule is also written as one sentence ("Route 4 waits for Route 1,
  so riders can connect."). A rule's state always carries text as well as colour,
  and every row control is a 44px target.

  The inspector reads the catalog's selected row and its competitors, so every
  sentence it renders — the rider meaning, the station-coverage count, the
  competing-rule count, the attention reasons and the GTFS values — comes from
  the annotated data. Data terms stay in the context and their wording stays here
  (CR-14).

  The page lists one of two views of the version. The view chips count the whole
  version's general rules and stay-on-board records, and the stay-on-board view
  renders read-only: the table keeps the same columns without checkboxes or a
  time, the toolbar drops Needs attention because those rows carry no reasons, a
  version without records says where they are managed, and the inspector names
  the record, its meaning and the Blocks handoff instead of the general
  inspector's actions. Nothing here creates, changes or deletes a type 4/5 row
  (R1).

  Below 1024px the two panes drill in instead of stacking: while a rule the URL
  names is open, the list is hidden and the right pane leads with a way back.
  `TransferDetailFocus` brings the pane to the top with focus on the rule's title
  when it opens, and returns focus to the rule's row when it closes.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents,
    only: [constraint_chip: 1, form_error_summary: 1, message: 1, sort_header: 1]

  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Values
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.Components.RouteIdentity
  alias LiveSelect.Component, as: LiveSelectComponent

  @quiet_class "inline-flex min-h-11 items-center gap-1.5 rounded-control px-2 text-sm font-[650] text-action hover:underline"
  @quiet_flush_class "inline-flex min-h-11 items-center gap-1.5 rounded-control text-sm font-[650] text-action hover:underline"
  @chip_class "inline-flex min-h-11 items-center gap-2 rounded-control border border-control bg-white px-3 text-sm font-semibold text-strong hover:bg-canvas aria-[pressed=true]:border-action aria-[pressed=true]:bg-selection aria-[pressed=true]:text-action"
  @secondary_class "inline-flex min-h-11 items-center justify-center gap-2 rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas disabled:cursor-not-allowed disabled:text-muted"
  @heading_class "font-display text-[24px] font-semibold tracking-[-0.025em] text-strong"

  # --- workspace ---------------------------------------------------------------

  @doc """
  Renders the two-pane transfer workspace.

  From `lg` up the list pane is the wider column (11fr to 9fr) and the context
  pane beside it stays in view while a long list scrolls. Below `lg` the panes
  drill in: `detail` is `"open"` while a rule (or a pick on the map) has the
  screen, `"closed"` while the list has it, and `"both"` while the editor shows
  its form over its preview. `"none"`, or no `:context` slot, gives the list the
  whole card, as a failed load does.

  ## Examples

      <.workspace detail="closed">
        <:list><.first_use /></:list>
        <:context><.context_empty /></:context>
      </.workspace>
  """
  attr :id, :string, default: "transfers-workspace"
  attr :detail, :string, values: ~w(open closed both none), default: "closed"
  attr :class, :any, default: nil
  slot :list, required: true, doc: "the rule list pane"
  slot :context, doc: "the selected connection's context pane"

  def workspace(assigns) do
    ~H"""
    <section
      id={@id}
      phx-hook=".TransferDetailFocus"
      data-detail={@detail}
      aria-label="Transfer workspace"
      class={[
        "group overflow-clip rounded-card border border-subtle bg-white",
        @context != [] && "lg:grid lg:grid-cols-[minmax(0,11fr)_minmax(0,9fr)]",
        @class
      ]}
    >
      <section aria-label="Transfer rules" class="min-w-0 max-lg:group-data-[detail=open]:hidden">
        {render_slot(@list)}
      </section>
      <section
        :if={@context != []}
        aria-label="Connection preview"
        class="min-w-0 border-t border-subtle lg:border-l lg:border-t-0 max-lg:group-data-[detail=closed]:hidden"
      >
        <div class="lg:sticky lg:top-3 lg:max-h-[calc(100vh-24px)] lg:overflow-y-auto lg:overscroll-contain">
          {render_slot(@context)}
        </div>
      </section>

      <%!-- Below 1024px opening a rule swaps the list for the rule, so the page
      would otherwise stay scrolled to where the row was and keyboard focus would
      sit on a hidden button. Opening the pane scrolls to the top and focuses the
      rule's title; closing it returns focus to the current row. --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".TransferDetailFocus">
        export default {
          mounted() {
            this.detail = this.el.dataset.detail;
          },
          updated() {
            const detail = this.el.dataset.detail;
            const previous = this.detail;
            this.detail = detail;

            if (!window.matchMedia("(max-width: 1023px)").matches) return;

            if (detail === "open" && previous !== "open") {
              // Remember the row the rule was opened from, and bring the rule's pane
              // to the top of the screen with focus on its title.
              const row = this.el.querySelector('#transfers button[aria-current="true"]');
              this.openedFrom = row ? row.id : null;

              const title = this.el.querySelector("#transfer-inspector-title");
              if (title) {
                this.el.scrollIntoView({block: "start"});
                title.focus({preventScroll: true});
              }
            } else if (detail === "closed" && previous === "open") {
              const row = this.openedFrom && document.getElementById(this.openedFrom);
              if (row) row.focus();
            }
          }
        };
      </script>
    </section>
    """
  end

  @doc """
  Renders the list pane's state when the transfer catalog could not load.

  The copy says what failed and what did not change, because a lost database
  connection leaves every stored rule intact. The retry reloads through the same
  adapter the first load used.

  ## Examples

      <.load_failure version_name="September 2026 service" />
  """
  attr :version_name, :string, required: true

  def load_failure(assigns) do
    ~H"""
    <div id="transfers-unavailable" class="p-4 md:p-5">
      <.message kind="error" title="Transfers couldn’t load">
        Your rules haven’t changed. Try loading {@version_name} again.
        <:action>
          <.button
            id="transfers-retry"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="retry_load"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Retry loading
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  @doc """
  Renders a callout that states a fact about the open rule, without a live
  region.

  The inspector renders several of these each time a different rule is chosen,
  so an assertive `role="alert"` on each would interrupt the reader on every
  selection. Errors that follow an action use `PlannerComponents.message/1`.

  ## Examples

      <.note kind="warning" title="This rule needs attention">…</.note>
  """
  attr :kind, :string, required: true, values: ~w(info warning)
  attr :title, :string, required: true
  attr :rest, :global
  slot :inner_block
  slot :action

  def note(assigns) do
    assigns =
      assign(
        assigns,
        :tone,
        case assigns.kind do
          "info" -> {"bg-soft text-cyan-800", "text-cyan-700", "hero-information-circle"}
          "warning" -> {"bg-warning-bg text-warning-fg", nil, "hero-exclamation-triangle"}
        end
      )

    ~H"""
    <div class={["flex items-start gap-3 rounded-control px-4 py-3", elem(@tone, 0)]} {@rest}>
      <.icon name={elem(@tone, 2)} class={["mt-0.5 size-5 shrink-0", elem(@tone, 1)]} />
      <div class="min-w-0 text-sm">
        <p class="font-bold">{@title}</p>
        <div :if={@inner_block != []} class="mt-1 space-y-1">{render_slot(@inner_block)}</div>
        <div :if={@action != []} class="mt-2">{render_slot(@action)}</div>
      </div>
    </div>
    """
  end

  # --- list pane ---------------------------------------------------------------

  @doc """
  Renders the list pane's two view chips.

  The chips are the page's view switcher: the left one lists the version's
  rules and the right one its stay-on-board records, each with the count the
  catalog loaded for the whole version rather than for the current filter, so an
  operator sees what a view holds before switching to it. Because type 4/5 rows
  are authored on Blocks, the stay-on-board view says so beside the chips.

  The pressed chip states `aria-pressed` and carries a check icon as well as its
  border, so which view is listed never rests on colour alone.

  ## Examples

      <.view_chips view={@view} counts={@catalog.counts} />
  """
  attr :view, :atom, required: true, values: [:general, :in_seat]
  attr :counts, :map, required: true, doc: "the catalog's `counts` for the whole version"

  def view_chips(assigns) do
    assigns = assign(assigns, :chip_class, @chip_class)

    ~H"""
    <div class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-subtle px-4 py-3 md:px-5">
      <div role="group" aria-label="Kinds of transfer" class="flex flex-wrap gap-2">
        <button
          id="transfers-view-general"
          type="button"
          aria-pressed={to_string(@view == :general)}
          phx-click="switch_view"
          phx-value-view="general"
          class={@chip_class}
        >
          <.icon :if={@view == :general} name="hero-check" class="size-4" /> Transfer rules
          <span class="tabular-nums">{@counts.general}</span>
        </button>
        <button
          id="transfers-view-in-seat"
          type="button"
          aria-pressed={to_string(@view == :in_seat)}
          phx-click="switch_view"
          phx-value-view="in_seat"
          class={@chip_class}
        >
          <.icon :if={@view == :in_seat} name="hero-check" class="size-4" /> Stay on board
          <span class="tabular-nums">{@counts.in_seat}</span>
        </button>
      </div>
      <p :if={@view == :in_seat} id="transfers-in-seat-note" class="text-[13px] text-muted">
        Read-only here. Blocks manages these.
      </p>
    </div>
    """
  end

  @doc """
  Renders the list pane's toolbar: the connection search, the kind of rule and
  the More filters disclosure.

  Search and kind are the two filters used on almost every visit, so they sit in
  the row; the stop and route selects are behind More filters, whose badge counts
  how many of those two apply. Every applied filter also shows as a removable
  chip in the count row, so a filtered deep link is legible before the
  disclosure is opened.

  The two server forms keep the ids the tests reach for: `transfer-search-form`
  patches as the operator types, and `transfer-filter-form` patches when a
  select changes.

  ## Examples

      <.list_toolbar
        search_form={@search_form}
        filter_form={@filter_form}
        filter_options={@catalog.filter_options}
        filter_count={1}
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
    doc: "how many of the stop and route selects currently apply"

  attr :filters_open?, :boolean, required: true, doc: "whether More filters is open"

  def list_toolbar(assigns) do
    ~H"""
    <div id="transfers-toolbar" role="search" class="border-b border-subtle px-4 py-4 md:px-5">
      <div class="flex flex-wrap items-end gap-3">
        <.form
          for={@search_form}
          id="transfer-search-form"
          phx-change="search"
          class="min-w-0 flex-1 basis-full sm:basis-[200px]"
        >
          <.input
            field={@search_form[:q]}
            type="search"
            label="Search transfers"
            placeholder="Stop, route or trip"
            phx-debounce="300"
          />
        </.form>

        <%!-- `contents` lets the form's children lay out in the toolbar row, so the
        kind select, the disclosure button and the two hidden selects belong to one
        server form without nesting it inside the search form. --%>
        <.form for={@filter_form} id="transfer-filter-form" phx-change="filter" class="contents">
          <div class="min-w-0 flex-1 basis-[150px] sm:w-[190px] sm:flex-none">
            <.input
              field={@filter_form[:type]}
              type="select"
              id="transfer-filter-type"
              label="Kind of rule"
              prompt="All kinds"
              options={type_filter_options(@filter_options.types)}
            />
          </div>
          <.button
            id="transfers-filters-toggle"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="toggle_filters"
            aria-expanded={to_string(@filters_open?)}
            aria-controls="transfer-filter-fields"
          >
            <.icon name="hero-adjustments-horizontal" class="size-4" /> More filters
            <span
              :if={@filter_count > 0}
              class="min-w-5 rounded-badge bg-selection px-1.5 text-center text-[13px] font-bold tabular-nums text-action"
            >
              {@filter_count}
            </span>
          </.button>
          <div
            id="transfer-filter-fields"
            hidden={!@filters_open?}
            class="grid basis-full gap-3 sm:grid-cols-2"
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
          </div>
        </.form>
      </div>
    </div>
    """
  end

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
      |> Enum.map(&Values.presence/1)
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> route_id
      _parts -> Enum.join(parts, " · ")
    end
  end

  defp type_filter_options(types), do: Enum.map(types, &{type_label(&1), &1})

  @doc """
  Renders the count row, or the selection bar while rules are checked.

  The row reads "13 transfer rules", or "5 of 13 transfer rules" while a filter
  narrows the list, with one removable chip per applied filter and, in the
  general view, the Needs attention toggle. Clear filters appears only while
  something is applied. It stays above the filtered-empty state, so an emptied
  list reads "0 of 13 transfer rules" instead of losing its count with its rows.

  Once a rule is checked, the general view's row is replaced by the selection
  bar: the number checked, Delete N rules, and Clear selection. Nothing here
  checks or deletes a type 4/5 record (R1), so the stay-on-board row keeps the
  count and its chips and nothing else.

  ## Examples

      <.rule_count total_count={12} all_count={12} in_seat?={false} chips={[]} />
      <.rule_count total_count={12} all_count={12} in_seat?={false} chips={[]} checked_count={2} />
  """
  attr :total_count, :integer, required: true, doc: "the rows the current list holds"
  attr :all_count, :integer, required: true, doc: "the rows the view holds without a filter"

  attr :in_seat?, :boolean,
    required: true,
    doc: "whether the count names stay-on-board records instead of rules"

  attr :chips, :list,
    default: [],
    doc: "the applied filters, as `%{key: \"q\", label: \"…\"}` maps"

  attr :attention?, :boolean, default: false, doc: "whether Needs attention is on"
  attr :checked_count, :integer, default: 0, doc: "how many of the shown rules are checked"

  def rule_count(assigns) do
    assigns =
      assigns
      |> assign(:quiet_class, @quiet_class)
      |> assign(:chip_class, @chip_class)

    if assigns.checked_count > 0 and not assigns.in_seat? do
      selection_bar(assigns)
    else
      summary_row(assigns)
    end
  end

  defp selection_bar(assigns) do
    ~H"""
    <div class="flex min-h-[52px] flex-wrap items-center gap-x-3 gap-y-1 border-b border-subtle bg-selection px-4 py-1 text-[13px] md:px-5">
      <p id="transfers-count" role="status" class="font-[650] tabular-nums text-strong">
        {@checked_count} selected
      </p>
      <.button
        id="transfers-delete-selected"
        type="button"
        variant="secondary"
        class="min-h-11"
        phx-click="delete_selected"
      >
        <.icon name="hero-trash" class="size-4" /> {delete_button_label(@checked_count)}
      </.button>
      <button
        id="transfers-clear-selection"
        type="button"
        phx-click="clear_selection"
        class={[@quiet_class, "ml-auto"]}
      >
        Clear selection
      </button>
    </div>
    """
  end

  defp summary_row(assigns) do
    assigns = assign(assigns, :filtered?, assigns.chips != [] or assigns.attention?)

    ~H"""
    <div
      id="transfers-summary"
      class="flex min-h-[52px] flex-wrap items-center gap-x-3 gap-y-1 border-b border-subtle px-4 py-1 text-[13px] md:px-5"
    >
      <p id="transfers-count" role="status" class="font-[650] tabular-nums text-strong">
        {count_label(@total_count, @all_count, @in_seat?)}
      </p>
      <div :if={@chips != []} class="flex flex-wrap items-center gap-2">
        <.constraint_chip
          :for={chip <- @chips}
          id={"transfers-chip-#{chip.key}"}
          key={chip.key}
          label={chip.label}
        />
      </div>
      <div class="ml-auto flex flex-wrap items-center gap-x-3">
        <button
          :if={not @in_seat?}
          id="transfers-attention-toggle"
          type="button"
          phx-click="toggle_attention"
          aria-pressed={to_string(@attention?)}
          class={[@chip_class, "text-[13px]"]}
        >
          <.icon name="hero-exclamation-triangle" class="size-4" /> Needs attention
        </button>
        <button
          :if={@filtered?}
          id="transfers-clear-filters"
          type="button"
          phx-click="clear_filters"
          class={@quiet_class}
        >
          Clear filters
        </button>
      </div>
    </div>
    """
  end

  defp count_label(total, all, in_seat?) when total == all, do: record_count_text(total, in_seat?)
  defp count_label(total, all, in_seat?), do: "#{total} of #{record_count_text(all, in_seat?)}"

  defp record_count_text(count, true),
    do: "#{count} #{Wording.noun(count, "stay-on-board record")}"

  defp record_count_text(count, false), do: "#{count} #{Wording.noun(count, "transfer rule")}"

  defp delete_button_label(1), do: "Delete 1 rule"
  defp delete_button_label(count), do: "Delete #{count} rules"

  @doc """
  Renders the list pane's table of rules.

  Each row names its two endpoints with the scope the rule applies to as subtext
  (a route badge and its name, a trip, or "Any route" — "whole station" for a
  station), its kind, and its minimum time right-aligned in tabular figures. A
  rule that needs attention carries a text badge under its arrival stop, so its
  state never depends on colour alone. Below `md` each row becomes one card: the
  two stops, then the kind and time.

  The rows are the `:transfers` stream, whose items are `{dom_id, row}` pairs with
  the `transfers-<uuid>` DOM ids the page contract fixes. Selection lives in the
  URL: the caller passes the selected id and the current sort, and a row button
  renders its own highlight from them. The arrival cell holds the row's one tab
  stop, whose overlay makes the whole row a target; the checkbox sits above it.

  The general view leads with a select column: one checkbox per row, labelled
  with the connection it selects, whose checked state is the map the caller
  passes, and a header checkbox that checks every row of the shown page. The
  stay-on-board view has no such column and no time, because a type 4/5 record is
  never checked or deleted here (R1).

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
        all_checked?={false}
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
    doc: "whether the rows are the read-only stay-on-board records"

  attr :checked, :map,
    default: %{},
    doc: "the checked rules, as `%{id => the updated_at the row carried when it was checked}`"

  attr :all_checked?, :boolean,
    default: false,
    doc: "whether every rule the page shows is checked"

  def rules_table(assigns) do
    ~H"""
    <div>
      <table
        id="transfers-table"
        aria-label={if(@in_seat?, do: "Stay-on-board records", else: "Transfer rules")}
        data-checkable={to_string(not @in_seat?)}
        class="transfers-table w-full table-fixed border-collapse text-left text-sm"
      >
        <colgroup>
          <col :if={not @in_seat?} class="w-11" />
          <col />
          <col />
          <col class="w-[112px]" />
          <col :if={not @in_seat?} class="w-[76px]" />
        </colgroup>
        <thead>
          <tr>
            <th
              :if={not @in_seat?}
              scope="col"
              class="sticky top-0 z-10 w-11 border-b border-subtle bg-canvas py-0 pl-4 pr-0"
            >
              <label class="flex size-11 items-center justify-center">
                <input
                  type="checkbox"
                  id="transfers-select-all"
                  checked={@all_checked?}
                  phx-click="toggle_check_all"
                  aria-label="Select all rules on this page"
                  class="size-5 accent-action"
                />
              </label>
            </th>
            <.sort_header
              label="Arrive at"
              sort_key="from"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              class="px-3 py-0"
            />
            <.sort_header
              label="Board at"
              sort_key="to"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              class="px-3 py-0"
            />
            <.sort_header
              label="Rule"
              sort_key="type"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              class="px-3 py-0"
            />
            <.sort_header
              :if={not @in_seat?}
              label="Time"
              sort_key="min_time"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              class="px-3 py-0 text-right"
            />
          </tr>
        </thead>
        <tbody id="transfers" phx-update="stream">
          <tr
            :for={{dom_id, row} <- @rows}
            id={dom_id}
            class="transfers-row border-b border-subtle last:border-b-0 hover:bg-canvas/70"
          >
            <td
              :if={not @in_seat?}
              data-label="Select"
              class="tx-check w-11 py-1 pl-4 pr-0 align-middle"
            >
              <label class="flex size-11 items-center justify-center">
                <input
                  type="checkbox"
                  id={"transfer-check-#{row.id}"}
                  checked={Map.has_key?(@checked, row.id)}
                  phx-click="toggle_check"
                  phx-value-id={row.id}
                  aria-label={"Select #{endpoint_name(row.from)} to #{endpoint_name(row.to)}"}
                  class="size-5 accent-action"
                />
              </label>
            </td>
            <td data-label="Arrive at" class="tx-from min-w-0 px-3 py-1.5 align-middle">
              <button
                id={"transfer-select-#{row.id}"}
                type="button"
                phx-click="select_rule"
                phx-value-id={row.id}
                aria-current={row.id == @selected_id && "true"}
                aria-label={"Inspect rule #{endpoint_name(row.from)} to #{endpoint_name(row.to)}"}
                class="tx-pick block min-h-11 w-full py-1 text-left"
              >
                <.endpoint_heading endpoint={row.from} />
                <span class="mt-0.5 flex flex-wrap items-center gap-1.5 text-[13px] text-muted">
                  <.scope endpoint={row.from} side={:from} table?={true} />
                </span>
              </button>
              <span
                :if={not @in_seat? and row.attention != []}
                id={"transfer-attention-#{row.id}"}
                class="mt-0.5 inline-flex items-center gap-1 rounded-badge bg-warning-bg px-2 py-0.5 text-[13px] font-[650] text-warning-fg"
              >
                <.icon name="hero-exclamation-triangle" class="size-3.5" /> Needs attention
              </span>
            </td>
            <td data-label="Board at" class="tx-to min-w-0 px-3 py-1.5 align-middle">
              <.endpoint_heading endpoint={row.to} arrow?={true} />
              <span class="mt-0.5 flex flex-wrap items-center gap-1.5 text-[13px] text-muted">
                <.scope endpoint={row.to} side={:to} table?={true} />
              </span>
            </td>
            <td data-label="Rule" class="tx-rule px-3 py-1.5 align-middle leading-snug text-strong">
              {type_short(row.transfer.transfer_type)}
            </td>
            <td
              :if={not @in_seat?}
              data-label="Time"
              class="tx-time px-3 py-1.5 text-right align-middle"
            >
              <.time_cell transfer={row.transfer} />
            </td>
          </tr>
        </tbody>
      </table>

      <p id="transfers-table-note" class="px-4 py-3 text-[13px] text-muted md:px-5">
        {table_footer(@in_seat?)}
      </p>

      <.page_nav
        page={@page}
        per_page={@per_page}
        total={@total_count}
        entity={pagination_entity(@in_seat?)}
      />
    </div>
    """
  end

  # A table cell's stop name: two lines at most, and muted when the rule stores no
  # stop. Below `md` the boarding stop leads with an arrow, so the card reads from
  # the arrival stop to the boarding stop.
  attr :endpoint, :map, required: true
  attr :arrow?, :boolean, default: false

  defp endpoint_heading(assigns) do
    ~H"""
    <span class={[
      "line-clamp-2 leading-snug",
      if(is_nil(@endpoint.stop_id), do: "font-normal text-muted", else: "font-[650] text-strong")
    ]}>
      <.icon
        :if={@arrow?}
        name="hero-arrow-right"
        class="mr-1.5 size-4 align-[-3px] text-muted md:hidden"
      />{endpoint_name(@endpoint)}
    </span>
    """
  end

  # The general view's footer names what a row selection drives; stay-on-board
  # rows are read-only here and kept in export.
  defp table_footer(true), do: "Read-only here. Every record stays in your export."
  defp table_footer(false), do: "Select a rule to see it on the map and what it means for riders."

  defp pagination_entity(true), do: "stay-on-board records"
  defp pagination_entity(false), do: "rules"

  # The Time cell: a minimum-time rule shows its time, or "Missing" in the warning
  # ink when it has none, and every other kind has no time to show.
  attr :transfer, :map, required: true

  defp time_cell(%{transfer: %{transfer_type: 2, min_transfer_time: nil}} = assigns) do
    ~H"""
    <span class="font-[650] text-warning-fg">Missing</span>
    """
  end

  defp time_cell(%{transfer: %{transfer_type: 2, min_transfer_time: seconds}} = assigns) do
    assigns = assign(assigns, :seconds, seconds)

    ~H"""
    <span class="tabular-nums">{min_time_label(@seconds)}</span>
    """
  end

  defp time_cell(assigns) do
    ~H"""
    <span class="text-muted">—</span>
    """
  end

  # Previous and Next through 50-row pages. Nothing renders while the list fits one
  # page.
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total, :integer, required: true
  attr :entity, :string, required: true

  defp page_nav(assigns) do
    pages = max(div(assigns.total + assigns.per_page - 1, assigns.per_page), 1)
    page = assigns.page |> max(1) |> min(pages)

    assigns =
      assigns
      |> assign(:pages, pages)
      |> assign(:current, page)
      |> assign(:from, (page - 1) * assigns.per_page + 1)
      |> assign(:to, min(page * assigns.per_page, assigns.total))
      |> assign(:secondary_class, @secondary_class)

    ~H"""
    <nav
      :if={@pages > 1}
      id="transfers-pagination"
      aria-label="Pages of transfer rules"
      class="flex flex-wrap items-center justify-between gap-3 border-t border-subtle px-4 py-3 md:px-5"
    >
      <p class="text-[13px] tabular-nums text-muted">
        Showing <strong class="font-[650] text-strong">{@from}–{@to}</strong> of {@total} {@entity}
      </p>
      <div class="flex items-center gap-2">
        <button
          type="button"
          phx-click="paginate"
          phx-value-page={@current - 1}
          disabled={@current <= 1}
          class={@secondary_class}
        >
          <.icon name="hero-chevron-left" class="size-4" /> Previous
        </button>
        <span class="text-[13px] tabular-nums text-muted">Page {@current} of {@pages}</span>
        <button
          type="button"
          phx-click="paginate"
          phx-value-page={@current + 1}
          disabled={@current >= @pages}
          class={@secondary_class}
        >
          Next <.icon name="hero-chevron-right" class="size-4" />
        </button>
      </div>
    </nav>
    """
  end

  # --- labels and sentences ----------------------------------------------------

  @type_labels %{
    0 => "Preferred transfer point",
    1 => "Timed transfer",
    2 => "Minimum time",
    3 => "Not possible",
    4 => "Stay on board",
    5 => "Must re-board"
  }

  @type_short_labels %{
    0 => "Preferred point",
    1 => "Timed transfer",
    2 => "Minimum time",
    3 => "Not possible",
    4 => "Stay on board",
    5 => "Must re-board"
  }

  # The GTFS reference's own name for each value, kept as secondary detail.
  @type_gtfs_labels %{
    0 => "Recommended transfer point",
    1 => "Timed transfer point",
    2 => "Minimum time required",
    3 => "Transfer not possible",
    4 => "In-seat transfer",
    5 => "In-seat transfer not allowed"
  }

  @doc """
  Labels a `transfer_type` for display, in rider and operator words.

  ## Examples

      iex> type_label(0)
      "Preferred transfer point"
  """
  def type_label(transfer_type), do: Map.get(@type_labels, transfer_type, "Unknown")

  @doc """
  The short form of `type_label/1` a table cell has room for.

  ## Examples

      iex> type_short(0)
      "Preferred point"
  """
  def type_short(transfer_type), do: Map.get(@type_short_labels, transfer_type, "Unknown")

  @doc """
  Formats a minimum transfer time in minutes and seconds, and as an em dash when a
  rule has no time stored.

  ## Examples

      iex> min_time_label(150)
      "2 min 30 sec"
      iex> min_time_label(180)
      "3 min"
      iex> min_time_label(45)
      "45 sec"
  """
  def min_time_label(nil), do: "—"

  def min_time_label(seconds) when is_integer(seconds) do
    case {div(seconds, 60), rem(seconds, 60)} do
      {0, remainder} -> "#{remainder} sec"
      {minutes, 0} -> "#{minutes} min"
      {minutes, remainder} -> "#{minutes} min #{remainder} sec"
    end
  end

  @doc """
  Names a rule's endpoint: the stop or station name, the stored stop id when the
  version no longer contains it, or "No stop recorded" when the rule stores no
  stop at all.

  ## Examples

      iex> endpoint_name(%{name: "Central · Bay A", stop_id: "CEN-A"})
      "Central · Bay A"
  """
  def endpoint_name(%{name: name}) when is_binary(name) and name != "", do: name
  def endpoint_name(%{stop_id: stop_id}) when is_binary(stop_id), do: stop_id
  def endpoint_name(_endpoint), do: "No stop recorded"

  @doc """
  Names the scope a rule applies to on one side of the connection as text: every
  arriving or departing route, one route (by short name when it has one), or one
  trip.

  ## Examples

      iex> selector_label(%{selector: {:route, "12"}, route: %{route_short_name: "12"}}, :from)
      "Route 12"
  """
  def selector_label(%{selector: :any}, :from), do: "Any arriving route"
  def selector_label(%{selector: :any}, :to), do: "Any departing route"

  def selector_label(%{selector: {:route, route_id}} = endpoint, _side) do
    "Route #{route_short_name(Map.get(endpoint, :route)) || route_id}"
  end

  def selector_label(%{selector: {:trip, trip_id}}, _side), do: "Trip #{trip_id}"

  # One side's scope as it reads in a table cell or the journey pair: a route badge
  # and the route's name, a trip (with its route's badge when the trip's route is
  # known), or the "any route" line. In a table cell a station reads "Any route ·
  # whole station", because its platforms are covered too.
  attr :endpoint, :map, required: true
  attr :side, :atom, required: true, values: [:from, :to]
  attr :table?, :boolean, default: false

  defp scope(%{endpoint: %{selector: {:trip, trip_id}} = endpoint} = assigns) do
    assigns = assign(assigns, trip_id: trip_id, route: Map.get(endpoint, :route))

    ~H"""
    <.route_badge :if={@route} route={@route} />
    <span>Trip {@trip_id}</span>
    """
  end

  defp scope(%{endpoint: %{selector: {:route, route_id}} = endpoint} = assigns) do
    route = Map.get(endpoint, :route) || %{route_id: route_id}

    assigns =
      assign(assigns,
        route: route,
        route_name: Values.presence(Map.get(route, :route_long_name))
      )

    ~H"""
    <.route_badge route={@route} />
    <span :if={@route_name} class="truncate">{@route_name}</span>
    """
  end

  defp scope(%{endpoint: endpoint, side: side, table?: table?} = assigns) do
    assigns = assign(assigns, :text, any_route_text(endpoint, side, table?))

    ~H"""
    <span>{@text}</span>
    """
  end

  defp any_route_text(%{child_count: count}, _side, true) when count > 0,
    do: "Any route · whole station"

  defp any_route_text(endpoint, side, _table?), do: selector_label(endpoint, side)

  # A route's badge. A screen reader hears "Route 12" and the route's name beside
  # it, not the bare number the badge shows.
  attr :route, :map, required: true

  defp route_badge(assigns) do
    assigns =
      assign(
        assigns,
        :spoken,
        "Route #{route_short_name(assigns.route) || assigns.route.route_id}"
      )

    ~H"""
    <span class="sr-only">{@spoken}</span>
    <span aria-hidden="true">
      <RouteIdentity.route_badge route={@route} class="min-h-6 min-w-6 text-[13px]" />
    </span>
    """
  end

  @doc """
  Writes one attention reason as the sentence a sighted operator reads (R11).

  The catalog annotates a row with the reasons it needs attention; the text lives
  here so every surface that shows a reason — the list's badge and the
  inspector's reason list — names it the same way. Each sentence says what is
  wrong and, where the operator has a choice, what to do.

  ## Examples

      iex> attention_text(:min_time_missing)
      "This rule needs a minimum time."
  """
  def attention_text({:competes, count}) do
    "Conflicts with #{count} other #{Wording.noun(count, "rule")} for the same trips."
  end

  def attention_text(:min_time_missing), do: "This rule needs a minimum time."

  def attention_text({:missing_stop, side, stop_id}) do
    "The #{side_word(side)} stop “#{stop_id}” is not in this version. " <>
      "Choose a stop that is, or delete the rule."
  end

  def attention_text({:invalid_stop_type, _side, stop_id, location_type}) do
    "“#{stop_id}” is #{article(Stop.location_type_label(location_type))}. " <>
      "Transfers need a stop, platform or station."
  end

  def attention_text({:missing_route, side, route_id}) do
    "The #{side_word(side)} route “#{route_id}” is not in this version."
  end

  def attention_text({:missing_trip, side, trip_id}) do
    "The #{side_word(side)} trip “#{trip_id}” is not in this version."
  end

  def attention_text({:trip_not_on_route, _side, trip_id, route_id}) do
    "Trip #{trip_id} is not on route #{route_id}."
  end

  def attention_text({:trip_not_at_stop, _side, trip_id, stop_id}) do
    "Trip #{trip_id} does not stop at #{stop_id}. Choose a trip that does, or use a route instead."
  end

  defp side_word(:from), do: "arriving"
  defp side_word(:to), do: "departing"

  defp article(label) do
    lowered = String.downcase(label)

    case lowered do
      <<first::utf8, _rest::binary>> when first in ~c"aeiou" -> "an " <> lowered
      _label -> "a " <> lowered
    end
  end

  defp route_short_name(route) when is_map(route),
    do: Values.presence(Map.get(route, :route_short_name))

  defp route_short_name(_route), do: nil

  @doc """
  Writes a rule as one sentence: what it means for riders and for the trip planners
  that read the feed.

  A minimum-time rule with a stored time names it, so the sentence carries the
  rule's own number; without one it asks for the time the kind requires. Either
  side reads as "Route 4", "trip 1-0815" or "any route".

  ## Examples

      iex> rule_sentence(3, nil, %{selector: {:route, "1"}}, %{selector: {:route, "4"}})
      "Trip planners will not offer a connection from Route 1 to Route 4."
  """
  def rule_sentence(type, min_time, from, to)

  def rule_sentence(0, _min, from, to) do
    "Trip planners prefer this place when riders switch from #{who(from)} to #{who(to)}. " <>
      "It does not make a vehicle wait."
  end

  def rule_sentence(1, _min, from, to) do
    subject = if any?(to), do: "Departing vehicles wait", else: "#{upcase_first(who(to))} waits"
    arriving = if any?(from), do: "arriving vehicles", else: who(from)

    "#{subject} for #{arriving}, so riders can connect."
  end

  def rule_sentence(2, nil, _from, _to) do
    "Trip planners need a minimum time for this connection. " <>
      "Set one so they know how long riders need."
  end

  def rule_sentence(2, min, from, to) do
    "Trip planners offer this connection only if riders have at least #{min_time_label(min)} " <>
      "between arriving on #{who(from)} and boarding #{who(to)}."
  end

  def rule_sentence(3, _min, from, to) do
    "Trip planners will not offer a connection from #{who(from)} to #{who(to)}."
  end

  def rule_sentence(4, _min, from, to) do
    "Riders can stay on board when #{who(from)} continues as #{who(to)}."
  end

  def rule_sentence(5, _min, from, to) do
    "Riders must get off and board again when #{who(from)} continues as #{who(to)}."
  end

  def rule_sentence(_type, _min, _from, _to), do: ""

  defp who(%{selector: {:trip, trip_id}}), do: "trip #{trip_id}"

  defp who(%{selector: {:route, route_id}} = endpoint),
    do: "Route #{route_short_name(Map.get(endpoint, :route)) || route_id}"

  defp who(_endpoint), do: "any route"

  defp any?(%{selector: :any}), do: true
  defp any?(_endpoint), do: false

  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp upcase_first(text), do: text

  # --- first use, empty and no-result states -----------------------------------

  @doc """
  Renders the list pane's first-use state for a version without general rules.

  It differs from `no_results/1`: nothing is hidden by a filter here, so the copy
  explains what a rule is for rather than undoing a query, and says that most
  connections need none. The caller supplies the "Create transfer rule" action.

  ## Examples

      <.first_use />
  """
  attr :class, :any, default: nil
  slot :action, doc: "the primary action that creates the version's first rule"

  def first_use(assigns) do
    assigns = assign(assigns, :heading_class, @heading_class)

    ~H"""
    <div id="transfers-first-use" class={["px-5 py-14 sm:px-10", @class]}>
      <div class="mx-auto max-w-[520px] text-center">
        <h2 class={@heading_class}>Most connections need no rule</h2>
        <p class="mt-2 text-sm text-muted">
          Trip planners already work out transfers from stop distance and timetables. Add a rule where that guess is wrong: a bus that waits, a longer walk, or a connection that should not be offered.
        </p>
        <div :if={@action != []} class="mt-6">{render_slot(@action)}</div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the stay-on-board view's empty state for a version without records.

  It offers no action, because type 4/5 rows are authored and removed on Blocks:
  there is nothing to create from here. The view chips above it stay reachable,
  so an operator can return to the rules.

  ## Examples

      <.in_seat_empty />
  """
  def in_seat_empty(assigns) do
    assigns = assign(assigns, :heading_class, @heading_class)

    ~H"""
    <div id="transfers-in-seat-empty" class="px-5 py-14 sm:px-10">
      <div class="mx-auto max-w-[520px] text-center">
        <h2 class={@heading_class}>No stay-on-board records yet</h2>
        <p class="mt-2 text-sm text-muted">
          Records that let riders stay on one vehicle across two trips are set up in Blocks, next to the vehicle’s day. They appear here once they exist.
        </p>
      </div>
    </div>
    """
  end

  @doc """
  Renders the list pane's filtered-empty state.

  The version has rules, but the search and filters hide all of them, so the state
  offers the way back — the bare list — instead of asking for a first rule. The
  toolbar above it stays visible, because the search term that emptied the list is
  edited there.

  ## Examples

      <.no_results all_count={13} />
  """
  attr :all_count, :integer, required: true, doc: "the rows the view holds without a filter"
  attr :in_seat?, :boolean, default: false

  def no_results(assigns) do
    assigns = assign(assigns, :secondary_class, @secondary_class)

    ~H"""
    <div id="transfers-no-results" class="px-5 py-12 text-center">
      <h2 class="font-sans text-base font-bold tracking-normal text-strong">
        No transfers match
      </h2>
      <p class="mx-auto mt-1.5 max-w-[46ch] text-sm text-muted">
        Try another stop, route or word, or clear the filters to see all {record_count_text(
          @all_count,
          @in_seat?
        )}.
      </p>
      <button
        id="transfers-no-results-clear"
        type="button"
        phx-click="clear_filters"
        class={[@secondary_class, "mt-5"]}
      >
        Clear filters
      </button>
    </div>
    """
  end

  # --- context pane: inspector --------------------------------------------------

  # One side of a journey: what riders do there, the service, the stop, and what kind
  # of place it is.
  attr :label, :string, required: true
  attr :side, :atom, required: true, values: [:from, :to]
  attr :endpoint, :map, required: true
  attr :name_id, :string, default: nil
  attr :missing?, :boolean, default: false

  defp journey_side(assigns) do
    assigns = assign(assigns, :context, endpoint_context(assigns.endpoint, assigns.missing?))

    ~H"""
    <div class="min-w-0">
      <p class="text-[13px] text-muted">{@label}</p>
      <p class="mt-1 flex flex-wrap items-center gap-1.5 text-sm text-strong">
        <.scope endpoint={@endpoint} side={@side} />
      </p>
      <p id={@name_id} class="mt-1 text-sm font-[650] leading-snug text-strong">
        <%= if is_nil(@endpoint.stop_id) do %>
          <span class="font-normal text-muted">No stop recorded</span>
        <% else %>
          {endpoint_name(@endpoint)}
        <% end %>
      </p>
      <p :if={@context} class="text-[13px] text-muted">{@context}</p>
    </div>
    """
  end

  # What kind of place an endpoint is, in the words a rider or operator uses.
  defp endpoint_context(%{stop_id: nil}, _missing?), do: nil
  defp endpoint_context(_endpoint, true), do: "Not in this version"

  defp endpoint_context(%{child_count: count}, _missing?) when count > 0,
    do: "Station · covers #{count} #{Wording.noun(count, "platform")}"

  defp endpoint_context(%{location_type: 1}, _missing?), do: "Station"

  defp endpoint_context(%{top_level: %{name: parent}}, _missing?) when is_binary(parent),
    do: "Platform at #{parent}"

  defp endpoint_context(%{platform_code: code}, _missing?) when is_binary(code) and code != "",
    do: "Platform #{code}"

  defp endpoint_context(_endpoint, _missing?), do: "Stop"

  # The journey pair: arrive here, board there, joined by an arrow. It is the same
  # shape in the inspector, in the live preview and (as text) in the dialogs, so the
  # operator reads one connection one way everywhere.
  attr :from, :map, required: true
  attr :to, :map, required: true
  attr :from_missing?, :boolean, default: false
  attr :to_missing?, :boolean, default: false

  attr :name_ids?, :boolean,
    default: false,
    doc: "whether the stop names carry the inspector's ids"

  defp journey_pair(assigns) do
    ~H"""
    <div class="rounded-card bg-canvas p-4">
      <div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)]">
        <.journey_side
          label="Riders arrive at"
          side={:from}
          endpoint={@from}
          missing?={@from_missing?}
          name_id={@name_ids? && "transfer-inspector-arrive"}
        />
        <.icon name="hero-arrow-right" class="hidden size-5 pt-6 text-muted sm:block" />
        <.journey_side
          label="Riders board at"
          side={:to}
          endpoint={@to}
          missing?={@to_missing?}
          name_id={@name_ids? && "transfer-inspector-board"}
        />
      </div>
    </div>
    """
  end

  @doc """
  Renders the way back from an open rule to the list, below 1024px.

  There the list and the rule take the screen in turn, so the rule's pane leads
  with this link, above the map, and the list returns with the rule's row where
  the operator left it. From `lg` up both panes are always on screen and the link
  is not drawn.

  ## Examples

      <.back_to_list path={~p"/gtfs/\#{@current_gtfs_version.id}/transfers"} />
  """
  attr :path, :string, required: true, doc: "the list without the open rule"

  def back_to_list(assigns) do
    assigns = assign(assigns, :quiet_class, @quiet_class)

    ~H"""
    <div class="border-b border-subtle px-2 lg:hidden">
      <.link id="transfer-inspector-back" patch={@path} class={@quiet_class}>
        <.icon name="hero-chevron-left" class="size-4" /> All transfer rules
      </.link>
    </div>
    """
  end

  @doc """
  Renders the context pane's inspector for the selected rule.

  The pane answers what a rule does: its kind, one plain sentence, the two
  endpoints with the scope each side covers, which direction it applies in with
  the next step inline, whether a station endpoint makes it station-wide, which
  equal-priority rules compete with it for the same trips, its attention reasons
  as text, and the stored GTFS values behind the summary under Technical
  details. Every reason the catalog annotates reaches the operator as words, so
  no state is carried by colour alone.

  The direction line reads "Works one way only: Route 1 to Route 4." because
  rules are one-directional (R7); it ends in "View the reverse rule" when the
  catalog found an exact mirror of the six key fields in the same view, and in
  "Create the reverse rule" when there is none. A station endpoint's coverage
  note counts the child platforms the rule covers, so an operator can see why a
  more specific route or trip rule may override it.

  The stay-on-board variant answers the same question for a record this page does
  not own: the title and sentence come from the same labels, and a note says the
  record is managed on Blocks. The direction line, the coverage and overlap
  notes, the attention list, the related links and the edit, reverse and delete
  actions are general-rule features — a stay-on-board record has none here (R1).

  ## Examples

      <.inspector
        row={@selected}
        competitors={@competitors}
        version_id={@current_gtfs_version.id}
        in_seat?={false}
      />
  """
  attr :row, :map, required: true, doc: "the catalog's selected `row()`"

  attr :competitors, :list,
    required: true,
    doc: "the selected row's competing rows, in the catalog's own order"

  attr :version_id, :string,
    required: true,
    doc: "the version the stop and route links belong to"

  attr :in_seat?, :boolean,
    required: true,
    doc: "whether the selected row is a read-only stay-on-board record"

  def inspector(assigns) do
    row = assigns.row

    assigns =
      assigns
      |> assign(:attention, attention_reasons(row))
      |> assign(:competitor_count, competitor_count(row))
      |> assign(:coverage, coverage_endpoints(row))
      |> assign(:detail_lines, detail_lines(row.transfer))
      |> assign(:from_route_id, route_id(row.from))
      |> assign(:to_route_id, route_id(row.to))
      |> assign(:sentence, row_sentence(row))
      |> assign(:from_missing?, missing_stop?(row, :from))
      |> assign(:to_missing?, missing_stop?(row, :to))
      |> assign(:quiet_class, @quiet_class)
      |> assign(:quiet_flush_class, @quiet_flush_class)
      |> assign(:heading_class, @heading_class)

    ~H"""
    <div id="transfer-inspector">
      <div class="px-4 py-5 md:px-6">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <h2 id="transfer-inspector-title" tabindex="-1" class={[@heading_class, "outline-none"]}>
            {type_label(@row.transfer.transfer_type)}
          </h2>
          <.button
            :if={not @in_seat?}
            id="transfer-inspector-edit"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="open_edit"
            phx-value-id={@row.id}
          >
            Edit rule
          </.button>
        </div>
        <p id="transfer-inspector-sentence" class="mt-1 text-[15px] leading-snug text-default">
          {@sentence}
        </p>

        <div class="mt-4 grid gap-4">
          <.journey_pair
            from={@row.from}
            to={@row.to}
            from_missing?={@from_missing?}
            to_missing?={@to_missing?}
            name_ids?={true}
          />

          <p
            :if={not @in_seat?}
            id="transfer-inspector-direction"
            class="flex flex-wrap items-center gap-x-2 text-sm text-muted"
          >
            <span>Works one way only: {who(@row.from)} to {who(@row.to)}.</span>
            <button
              :if={@row.reverse_id}
              id="transfer-inspector-reverse-inspect"
              type="button"
              phx-click="inspect_reverse"
              class={@quiet_flush_class}
            >
              View the reverse rule
            </button>
            <button
              :if={is_nil(@row.reverse_id)}
              id="transfer-inspector-reverse-create"
              type="button"
              phx-click="reverse_draft"
              class={@quiet_flush_class}
            >
              Create the reverse rule
            </button>
          </p>

          <.note
            :if={@in_seat?}
            id="transfer-inspector-blocks-note"
            kind="info"
            title="Managed in Blocks"
          >
            <p>
              Stay-on-board records are set on the block that runs both trips. Changes are made there.
            </p>
          </.note>

          <.note
            :if={not @in_seat? and @coverage != []}
            id="transfer-inspector-coverage"
            kind="info"
            title="Covers the whole station"
          >
            <p :for={endpoint <- @coverage}>{coverage_sentence(endpoint)}</p>
          </.note>

          <.note
            :if={not @in_seat? and @competitor_count > 0}
            id="transfer-inspector-overlap"
            kind="warning"
            title="Rules disagree for the same trips"
          >
            <p>{overlap_sentence(@competitor_count)}</p>
            <:action>
              <.button
                id="transfer-inspector-compare"
                type="button"
                variant="secondary"
                class="min-h-11"
                phx-click="open_compare"
              >
                Compare rules
              </.button>
            </:action>
          </.note>

          <.note
            :if={not @in_seat? and @attention != []}
            id="transfer-inspector-attention"
            kind="warning"
            title={attention_title(length(@attention))}
          >
            <ul class="list-disc space-y-1 pl-5">
              <li :for={reason <- @attention}>{attention_text(reason)}</li>
            </ul>
          </.note>

          <details id="transfer-inspector-details" class="group/details border-t border-subtle pt-3">
            <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 text-sm font-semibold text-strong [&::-webkit-details-marker]:hidden">
              <.icon
                name="hero-chevron-right"
                class="size-4 text-muted group-open/details:rotate-90"
              /> Technical details
            </summary>
            <div class="pb-1 pt-1 text-[13px] text-muted">
              <p>
                <strong class="font-[650] text-default">{specificity_label(@row)}</strong>
                · GTFS specificity {specificity_rank(@row)} of 6 · {gtfs_label(
                  @row.transfer.transfer_type
                )}
              </p>
              <dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
                <%= for {field, value} <- @detail_lines do %>
                  <dt class="font-mono">{field}</dt>
                  <dd class="text-default">{value}</dd>
                <% end %>
              </dl>
              <p class="mt-2">
                Trip and route choices narrow a rule. Rules with the same specificity that overlap need review.
              </p>
            </div>
          </details>

          <div :if={not @in_seat?} class="flex flex-wrap gap-x-5">
            <.link
              :if={@row.from.stop_id}
              id="transfer-inspector-stop-link"
              navigate={~p"/gtfs/#{@version_id}/stops/#{@row.from.stop_id}"}
              class="inline-flex min-h-11 items-center text-sm font-semibold text-action hover:underline"
            >
              View {endpoint_name(@row.from)}
            </.link>
            <.link
              :if={@from_route_id}
              id="transfer-inspector-route-link-from"
              navigate={~p"/gtfs/#{@version_id}/routes/#{@from_route_id}"}
              class="inline-flex min-h-11 items-center text-sm font-semibold text-action hover:underline"
            >
              View route {route_label(@row.from)}
            </.link>
            <.link
              :if={not is_nil(@to_route_id) and @to_route_id != @from_route_id}
              id="transfer-inspector-route-link-to"
              navigate={~p"/gtfs/#{@version_id}/routes/#{@to_route_id}"}
              class="inline-flex min-h-11 items-center text-sm font-semibold text-action hover:underline"
            >
              View route {route_label(@row.to)}
            </.link>
          </div>

          <div :if={not @in_seat?} class="border-t border-subtle pt-2">
            <button
              id="transfer-inspector-delete"
              type="button"
              phx-click="confirm_delete"
              class="-ml-2 inline-flex min-h-11 items-center gap-1.5 rounded-control px-2 text-sm font-[650] text-error-fg hover:underline"
            >
              <.icon name="hero-trash" class="size-4" /> Delete rule
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp row_sentence(row) do
    rule_sentence(
      row.transfer.transfer_type,
      row.transfer.min_transfer_time,
      row.from,
      row.to
    )
  end

  defp missing_stop?(row, side) do
    Enum.any?(row.attention, &match?({:missing_stop, ^side, _stop_id}, &1))
  end

  defp attention_title(1), do: "This rule needs attention"
  defp attention_title(count), do: "#{count} things need attention"

  @doc """
  Names how narrow a rule's selectors are, from the rank the catalog computed.

  A rule that names a trip on either side applies to specific trips; a rule that
  names only routes is route-specific; a rule with no selectors is the stop or
  station default that other rules override.

  ## Examples

      iex> specificity_label(%{rank: 4})
      "Route-specific"
  """
  def specificity_label(%{rank: rank}) when rank in 1..3, do: "Specific trips"
  def specificity_label(%{rank: rank}) when rank in 4..5, do: "Route-specific"
  def specificity_label(_row), do: "Every service at these stops"

  defp specificity_rank(%{rank: rank}) when rank in 1..6, do: rank
  defp specificity_rank(_row), do: 6

  defp gtfs_label(type), do: Map.get(@type_gtfs_labels, type, "Unknown")

  # The competition reason is the overlap note's own; every other reason renders in
  # the attention list, as text (R11).
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

    "#{endpoint_name(endpoint)} includes #{count} #{Wording.noun(count, "platform")}, " <>
      "so this rule applies at every one. A rule for a specific route or trip overrides it."
  end

  defp overlap_sentence(count) do
    "#{count} other #{Wording.noun(count, "rule")} of equal priority can apply to some of the " <>
      "same trips, so a trip planner can’t tell which one wins. " <>
      "Keep one, or narrow one to a route or trip."
  end

  # The eight stored GTFS columns behind the rule: the two stops always name what
  # the rule stores, the selectors only when the rule has one, and the kind and the
  # minimum time as the rule holds them.
  defp detail_lines(transfer) do
    [
      {"from_stop_id", transfer.from_stop_id || "not set"},
      {"to_stop_id", transfer.to_stop_id || "not set"},
      {"from_route_id", transfer.from_route_id},
      {"to_route_id", transfer.to_route_id},
      {"from_trip_id", transfer.from_trip_id},
      {"to_trip_id", transfer.to_trip_id},
      {"transfer_type", transfer.transfer_type},
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

  With rows in the view but none chosen it says what choosing does; with no rows
  at all (or none the filters leave) it says where a connection will appear. The
  stay-on-board view names Blocks, because that is where its records begin.

  ## Examples

      <.context_empty none?={false} in_seat?={false} />
  """
  attr :none?, :boolean,
    default: false,
    doc: "whether the view holds no rows at all, rather than none chosen"

  attr :in_seat?, :boolean, default: false

  def context_empty(assigns) do
    assigns = assign(assigns, :heading_class, @heading_class)

    ~H"""
    <div id="transfer-inspector-empty" class="px-4 py-6 md:px-6">
      <h2 class={@heading_class}>{context_empty_title(@none?, @in_seat?)}</h2>
      <p class="mt-2 max-w-[52ch] text-sm text-muted">{context_empty_text(@none?, @in_seat?)}</p>
    </div>
    """
  end

  defp context_empty_title(true, true), do: "Stay-on-board records appear here"
  defp context_empty_title(true, false), do: "Connections appear here"
  defp context_empty_title(false, _in_seat?), do: "Choose a rule to see the connection"

  defp context_empty_text(true, true) do
    "Each record set up in Blocks appears here on the map, with what it means for riders."
  end

  defp context_empty_text(true, false) do
    "Each rule you add appears here on the map, with what it means for riders and trip planners."
  end

  defp context_empty_text(false, _in_seat?) do
    "It appears on the map with what it means for riders and trip planners."
  end

  @doc """
  Renders the compare view for a rule that competes with equal-priority rules.

  It lists the selected rule and every competitor with the effect each one has —
  its kind and minimum time — each with an "Edit rule" action that opens that
  rule's own editor, so the operator can see why none is more specific and then
  correct the one that should change.

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
      chrome="planner"
      size="lg"
      single_action={true}
      title="Rules that match the same trips"
      confirm_label="Close"
      cancel_label="Close"
      pending_label="Closing…"
      on_confirm="close_compare"
      on_cancel="close_compare"
      described_by="transfer-compare-dialog-body"
      return_focus_id="transfer-inspector-compare"
    >
      <p class="text-default">
        These rules can apply to some of the same trips and none is more specific, so a trip planner can’t tell which one wins. Keep the one you intend, then narrow the other to a route or trip, or delete it.
      </p>
      <ul class="mt-4 grid gap-2">
        <li
          :for={rule <- @rules}
          class={[
            "flex flex-wrap items-start justify-between gap-3 rounded-card border p-3",
            if(rule.id == @row.id, do: "border-action bg-selection", else: "border-subtle")
          ]}
        >
          <div class="min-w-0 flex-1">
            <p :if={rule.id == @row.id} class="mb-1 text-[13px] font-[650] text-action">
              Selected rule
            </p>
            <p class="text-sm font-bold text-strong">
              {type_label(rule.transfer.transfer_type)}{compare_time(rule.transfer)}
            </p>
            <p class="mt-0.5 text-sm text-default">
              {endpoint_name(rule.from)} to {endpoint_name(rule.to)}
            </p>
            <p class="mt-0.5 text-[13px] text-muted">
              {selector_label(rule.from, :from)} to {selector_label(rule.to, :to)}
            </p>
          </div>
          <.button
            id={"transfer-compare-edit-#{rule.id}"}
            type="button"
            variant="secondary"
            class="min-h-11 shrink-0"
            phx-click="compare_edit"
            phx-value-id={rule.id}
          >
            Edit rule
          </.button>
        </li>
      </ul>
    </.confirm_dialog>
    """
  end

  defp compare_time(%{transfer_type: 2, min_transfer_time: seconds}) when is_integer(seconds),
    do: " · #{min_time_label(seconds)}"

  defp compare_time(_transfer), do: ""

  # --- context pane: connection map -------------------------------------------

  @doc """
  Renders the context pane's connection map.

  The region is the map's title row, canvas, legend and its two failure
  affordances. The canvas is the `TransferMap` hook's own container —
  `phx-update="ignore"`, so the server never patches inside it — while every
  control and sentence the operator reads lives outside it, so a map that never
  loads leaves the list, the inspector and the form working (AC-22).

  The title says what the map is drawing: the selected rule, the open draft, or
  the side a pick session is waiting for. Pick mode says how to answer and how to
  leave it, and the named stop fields stay the keyboard alternative. The version's
  bounding box travels as the hook's `data-extent`, read once at mount.

  ## Examples

      <.map_region
        editor_open?={false}
        pick={@pick}
        map_state={@map_state}
        generation={@map_generation}
        extent={@map_extent}
        missing={@map_missing}
      />
  """
  attr :editor_open?, :boolean, required: true, doc: "whether the draft editor is open"
  attr :pick, :map, default: nil, doc: "the active pick session, or nil"
  attr :map_state, :atom, required: true, values: [:ready, :unavailable]
  attr :generation, :string, required: true, doc: "the mount's map generation"
  attr :extent, :map, default: nil, doc: "the version's bounding box, or nil"

  attr :missing, :list,
    required: true,
    doc: "the connection's endpoints the payload reports without coordinates"

  def map_region(assigns) do
    assigns =
      assigns
      |> assign(:title, map_title(assigns))
      |> assign(:quiet_class, @quiet_class)
      |> assign(:secondary_class, @secondary_class)

    ~H"""
    <div id="transfer-map-region" class="border-b border-subtle">
      <div class="flex min-h-12 items-center justify-between gap-3 px-4 py-1 md:px-6">
        <h3 id="transfer-map-title" class="text-sm font-bold text-strong">{@title}</h3>
        <button
          id="transfer-map-fit"
          type="button"
          class={@quiet_class}
          phx-click={JS.dispatch("transfer-map:fit", to: "#transfer-map")}
        >
          Fit connection
        </button>
      </div>

      <div :if={@pick} class="mx-4 mb-3 md:mx-6">
        <.note id="transfer-pick-callout" kind="info" title="Pick on the map">
          <p>Select a stop on the map, or type its name in the search field.</p>
          <p :if={@pick.truncated?} id="transfer-pick-truncated">Zoom in to see all stops.</p>
          <:action>
            <button
              id="transfer-pick-cancel"
              type="button"
              class={@secondary_class}
              phx-click="cancel_pick"
              phx-window-keydown="cancel_pick"
              phx-key="Escape"
            >
              Cancel picking
            </button>
          </:action>
        </.note>
      </div>

      <div class={if(@map_state == :unavailable, do: "hidden")}>
        <div
          id="transfer-map"
          phx-hook="TransferMap"
          phx-update="ignore"
          data-map-generation={@generation}
          data-extent={Jason.encode!(@extent || %{})}
          class="h-[250px] w-full lg:h-[320px]"
        >
        </div>
      </div>

      <div
        :if={@map_state == :unavailable}
        id="transfer-map-unavailable"
        class="grid h-[250px] place-content-center justify-items-center gap-1 bg-canvas px-6 text-center lg:h-[320px]"
      >
        <h3 class="text-base font-bold text-strong">Map unavailable</h3>
        <p class="max-w-[34ch] text-sm text-muted">
          Stop names and rule details still work. Try the map again in a moment.
        </p>
        <button
          id="transfer-map-retry"
          type="button"
          class={[@secondary_class, "mt-3"]}
          phx-click="retry_map"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Retry map
        </button>
      </div>

      <div
        :if={@map_state == :ready}
        id="transfer-map-legend"
        class="flex flex-wrap items-center gap-x-4 gap-y-1 border-t border-subtle px-4 py-2 text-[13px] text-muted md:px-6"
      >
        <span class="inline-flex items-center gap-1.5">
          <span class="inline-block size-3 rounded-full bg-strong"></span>Riders arrive
        </span>
        <span class="inline-flex items-center gap-1.5">
          <span class="inline-block size-3 rounded-full bg-cyan-700"></span>Riders board
        </span>
        <span class="inline-flex items-center gap-1.5">
          <.icon name="hero-arrow-right" class="size-4" />Direction of the rule, not a walking route
        </span>
      </div>

      <ul
        :if={@map_state == :ready and @missing != []}
        id="transfer-map-missing"
        class="border-t border-subtle px-4 py-2 text-[13px] text-muted md:px-6"
      >
        <li :for={name <- @missing}>{name} has no location in this version.</li>
      </ul>
    </div>
    """
  end

  defp map_title(%{pick: %{side: :from}}), do: "Choose where riders arrive"
  defp map_title(%{pick: %{side: :to}}), do: "Choose where riders board"
  defp map_title(%{editor_open?: true}), do: "Preview of this connection"
  defp map_title(_assigns), do: "Selected connection"

  # --- dialogs ------------------------------------------------------------------

  @doc """
  Renders the confirmation for deleting the rules the operator selected.

  The dialog lists every rule it will delete — both endpoints with the scope each
  side covers, and the kind — and names the version the deletion lands in, so the
  operator confirms named rules rather than a count (R8). The change log cannot
  roll a transfer rule back, so the dialog says the deletion can't be undone
  instead of offering an undo, and the safe button takes focus. A refusal keeps
  the dialog open with its reason, because the rules the click captured no longer
  match what a confirm would delete; when a retry cannot change that outcome, only
  Close remains.

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
    count = length(assigns.dialog.rows)

    assigns =
      assigns
      |> assign(:count, count)
      |> assign(:final?, assigns.dialog.error in [:stale, :not_found, :forbidden])

    ~H"""
    <.confirm_dialog
      id="transfer-delete-dialog"
      open={true}
      chrome="planner"
      size="lg"
      title={delete_dialog_title(@count)}
      confirm_label={delete_button_label(@count)}
      cancel_label={if(@final?, do: "Close", else: keep_label(@count))}
      pending_label="Deleting…"
      single_action={@final?}
      on_confirm="apply_delete"
      on_cancel="cancel_delete"
      confirm_variant="danger"
      described_by="transfer-delete-dialog-body"
      return_focus_id={@dialog.return_focus_id}
    >
      <ul class="max-h-64 overflow-auto rounded-card border border-subtle">
        <li
          :for={row <- @dialog.rows}
          id={"transfer-delete-row-#{row.id}"}
          class="border-b border-subtle px-3 py-2 last:border-b-0"
        >
          <strong class="block text-sm text-strong">
            {endpoint_name(row.from)} to {endpoint_name(row.to)}
          </strong>
          <span class="block text-[13px] text-muted">
            {selector_label(row.from, :from)} to {selector_label(row.to, :to)} · {type_short(
              row.transfer.transfer_type
            )}
          </span>
        </li>
      </ul>
      <p class="mt-4 text-default">
        {if @count == 1, do: "This rule", else: "These rules"} will be removed from {@version_name} and from its next export. Stops, routes and other rules stay as they are. This can’t be undone.
      </p>
      <div :if={@dialog.error} class="mt-4">
        <.message id="transfer-delete-error" kind="error" title="Nothing was deleted.">
          {delete_error_text(@dialog.error)}
        </.message>
      </div>
    </.confirm_dialog>
    """
  end

  defp delete_dialog_title(1), do: "Delete 1 transfer rule?"
  defp delete_dialog_title(count), do: "Delete #{count} transfer rules?"

  defp keep_label(1), do: "Keep rule"
  defp keep_label(_count), do: "Keep rules"

  # The refusals the delete facades answer, under the band's own "Nothing
  # was deleted.": each reason says what happened to the selection the dialog was
  # built from.
  defp delete_error_text(:stale) do
    "One or more rules changed after you selected them. Close this dialog to see the latest rules."
  end

  defp delete_error_text(:not_found) do
    "One or more rules were already removed or can’t be deleted here. Close this dialog to see the latest list."
  end

  defp delete_error_text(:forbidden) do
    "You no longer have permission to delete transfer rules. Your selection is still here."
  end

  defp delete_error_text(_busy) do
    "The server didn’t respond. Try again."
  end

  @doc """
  Renders the confirmation that guards a dirty draft's departure (AC-20).

  The draft is what the operator typed, and every way out of the editor — Back,
  Cancel, "Open existing rule", a link departure and a version switch — runs
  through the same question, so none of them silently discards it. The confirm
  names what is lost; "Keep editing" returns to the draft with focus on the save
  button.

  ## Examples

      <.discard_dialog open={@pending_discard != nil} mode={:create} />
  """
  attr :open, :boolean, required: true, doc: "whether a departure is waiting for an answer"

  attr :mode, :atom,
    default: :create,
    values: [:create, :edit, nil],
    doc: "whether the draft is a new rule or a stored one"

  def discard_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="transfer-discard-dialog"
      open={@open}
      chrome="planner"
      title="Discard unsaved changes?"
      confirm_label="Discard changes"
      cancel_label="Keep editing"
      pending_label="Discarding…"
      on_confirm="discard_changes"
      on_cancel="keep_editing"
      confirm_variant="danger"
      described_by="transfer-discard-dialog-body"
      return_focus_id="transfer-save"
    >
      <p>
        {if @mode == :edit,
          do: "The saved rule stays as it was.",
          else: "Nothing has been saved yet."} The changes in this form will be lost.
      </p>
    </.confirm_dialog>
    """
  end

  # --- create and edit ----------------------------------------------------------

  # The three scopes the editor offers. A scope is the operator's workflow choice;
  # the stored rule keeps only GTFS fields.
  @scope_choices [
    {"stops", "Every route at these stops", "Use a station to cover all its platforms."},
    {"routes", "One route to another", "Only riders switching between the two routes you pick."},
    {"custom", "Specific trips or a mix",
     "Narrow either side to a trip, or mix a route on one side with anything on the other."}
  ]

  # The four kinds a general rule can be, most used first; the GTFS numbering is
  # secondary detail on each card.
  @type_choices [
    {1, "The departing vehicle waits for the arriving one so riders can connect."},
    {2, "Trip planners only offer the connection if riders get at least this long."},
    {3, "Trip planners never offer a connection between these two."},
    {0, "Trip planners choose this place first when riders could change routes at several."}
  ]

  @stop_hint_unset "Choose a stop or a whole station from this version."

  @doc """
  Renders the create/edit editor in place of the list pane.

  The form asks in the order its answers depend on each other: where riders
  change (a stop search each, with Pick on map), which services that covers (three
  cards, then the route and trip selects the scope allows), and what should happen
  (four cards, then the minimum time a minimum-time rule requires with its live
  readout). The draft's own values are the form's: the LiveView clears the
  dependents of a changed stop or route and reloads the option lists, and this
  component renders whatever the draft holds.

  A `nil` `error` renders nothing; a duplicate names the colliding row's view — a
  general rule can be edited, which the duplicate's "Open existing rule" does, and
  a type 4/5 record cannot (R1) — the stale notice keeps the draft and offers the
  reload, and the busy notice keeps the draft and offers the retry. A rejected
  save lists every invalid field in a summary that links to it, and each field
  also carries its own error.

  The editor is a general-view surface: the page renders it for the general view
  only, in the create and the edit mode, and its one write is the save.

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
    doc: "the stay-on-board list of this version, for a collision with a type 4/5 record"

  def editor(assigns) do
    editor = assigns.editor

    assigns =
      assigns
      |> assign(:from_stop_errors, field_errors(editor.form, :from_stop_id))
      |> assign(:to_stop_errors, field_errors(editor.form, :to_stop_id))
      |> assign(:type_errors, field_errors(editor.form, :transfer_type))
      |> assign(:type_choices, @type_choices)
      |> assign(:scope_choices, @scope_choices)
      |> assign(:draft_type, draft_type(editor))
      |> assign(:draft_time, draft_min_time(editor))
      |> assign(:failures, summary_failures(editor))
      |> assign(:open_existing_id, open_existing_id(editor.error))
      |> assign(:secondary_class, @secondary_class)
      |> assign(:quiet_class, @quiet_class)
      |> assign(:heading_class, @heading_class)

    ~H"""
    <div
      id="transfer-editor"
      phx-hook="DraftGuard"
      data-dirty={to_string(@editor.dirty?)}
      data-depart-event="transfer_depart"
      data-discard-message="Discard unsaved transfer changes? Cancel to keep editing."
      data-focus-on-mount="transfer-editor-title"
      class="px-4 py-5 md:px-6"
    >
      <button
        id="transfer-back"
        type="button"
        class={[@quiet_class, "-ml-2"]}
        phx-click="cancel_editor"
      >
        <.icon name="hero-chevron-left" class="size-4" /> Back to transfers
      </button>

      <h2
        id="transfer-editor-title"
        tabindex="-1"
        class={[@heading_class, "mt-1 outline-none"]}
      >
        {editor_title(@editor)}
      </h2>
      <p class="mt-1 text-[13px] text-muted">{@version_name} · works in one direction</p>

      <div :if={@editor.error != nil or @failures != []} class="mt-4 grid gap-4">
        <%!-- A rule that moved on while the editor was open: the draft the operator
        entered is kept, and the reload path is the way back to the stored values. --%>
        <.message
          :if={@editor.error == :stale}
          id="transfer-stale"
          kind="warning"
          title="This rule changed while you were editing"
        >
          Someone saved a change to it. Your entries are still here. Reload the rule to see what changed before you save.
          <:action>
            <.button
              id="transfer-reload-rule"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="reload_rule"
            >
              Reload rule
            </.button>
          </:action>
        </.message>

        <.message
          :if={@editor.error not in [nil, :stale]}
          id="transfer-form-error"
          kind="error"
          title={form_error_title(@editor.error)}
        >
          {form_error_text(@editor.error)}
          <:action :if={in_seat_duplicate?(@editor.error)}>
            <.link
              id="transfer-view-in-seat-link"
              patch={@in_seat_path}
              class={[@secondary_class, "no-underline"]}
            >
              View stay-on-board records
            </.link>
          </:action>
          <:action :if={@open_existing_id}>
            <.button
              id="transfer-open-existing"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="open_existing"
              phx-value-id={@open_existing_id}
            >
              Open existing rule
            </.button>
          </:action>
          <:action :if={@editor.error == :busy}>
            <.button
              id="transfer-retry-save"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="retry_save"
            >
              Retry saving
            </.button>
          </:action>
        </.message>

        <.form_error_summary
          id="transfer-error-summary"
          title={summary_title(length(@failures))}
          failures={@failures}
          class=""
        />
      </div>

      <.form
        for={@editor.form}
        id="transfer-form"
        novalidate
        phx-change="editor_change"
        phx-submit="save"
      >
        <section aria-labelledby="transfer-step-1" class="mt-6 grid gap-4 border-t border-subtle pt-5">
          <.step_head id="transfer-step-1" number={1} title="Where do riders change?">
            Riders arrive at the first stop and board at the second. Add the reverse rule separately if they need it.
          </.step_head>
          <.stop_field
            side={:from}
            label="Riders arrive at"
            editor={@editor}
            errors={@from_stop_errors}
          />
          <.stop_field side={:to} label="Riders board at" editor={@editor} errors={@to_stop_errors} />
        </section>

        <fieldset class="mt-6 grid gap-3 border-t border-subtle pt-5">
          <legend class="sr-only">Which services this covers</legend>
          <.step_head id="transfer-step-2" number={2} title="Which services does it cover?" />
          <div id="transfer-scope" class="grid gap-2">
            <.choice_card
              :for={{value, title, help} <- @scope_choices}
              id={"transfer-scope-#{value}"}
              name="scope"
              value={value}
              checked={scope_value(@editor.scope) == value}
              title={title}
              help={help}
            />
          </div>
          <div :if={@editor.scope != :stops} class="grid gap-3 sm:grid-cols-2">
            <.route_select side={:from} editor={@editor} />
            <.route_select side={:to} editor={@editor} />
          </div>
          <div :if={@editor.scope == :custom} class="grid gap-3 sm:grid-cols-2">
            <.trip_select side={:from} editor={@editor} />
            <.trip_select side={:to} editor={@editor} />
          </div>
        </fieldset>

        <fieldset class="mt-6 grid gap-3 border-t border-subtle pt-5">
          <legend class="sr-only">What should happen</legend>
          <.step_head id="transfer-step-3" number={3} title="What should happen?" />
          <div class="grid gap-2">
            <.choice_card
              :for={{value, help} <- @type_choices}
              id={"transfer-type-#{value}"}
              name={@editor.form[:transfer_type].name}
              value={to_string(value)}
              checked={@draft_type == value}
              title={type_label(value)}
              help={help}
              detail={"GTFS: transfer_type #{value}"}
            />
          </div>
          <p :for={message <- @type_errors} class={error_class()}>
            <.icon name="hero-exclamation-circle" class="mt-px size-4 shrink-0" />{message}
          </p>

          <div :if={@draft_type == 2}>
            <.input
              id="transfer-min-time"
              field={live_field(@editor.form, :min_transfer_time)}
              type="number"
              min="0"
              step="1"
              inputmode="numeric"
              label="Minimum time in seconds"
            />
            <p id="transfer-min-time-readout" class="mt-1.5 text-[13px] text-muted">
              {min_time_readout(@draft_time)}
            </p>
          </div>
        </fieldset>

        <p class="mt-6 border-t border-subtle pt-4 text-[13px] text-muted">
          Looking for a stay-on-board connection? Those are set in Blocks.
        </p>

        <div class="mt-3 flex flex-wrap items-center gap-3">
          <.button
            id="transfer-save"
            type="submit"
            class="min-h-11 min-w-[132px]"
            phx-disable-with="Saving…"
          >
            {save_label(@editor)}
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
          <span :if={@editor.dirty?} id="transfer-dirty" class="text-[13px] text-muted">
            Unsaved changes
          </span>
        </div>
      </.form>
    </div>
    """
  end

  # The minutes-and-seconds reading of what the operator has typed, then what the
  # time should cover; before anything valid is typed there is only the guidance.
  defp min_time_readout(nil),
    do: "Include the walk between the stops and a buffer for late buses."

  defp min_time_readout(seconds),
    do:
      "#{min_time_label(seconds)} · include the walk between the stops and a buffer for late buses."

  defp editor_title(%{mode: :edit}), do: "Edit transfer rule"
  defp editor_title(_editor), do: "Create transfer rule"

  defp save_label(%{mode: :edit}), do: "Save changes"
  defp save_label(_editor), do: "Create rule"

  defp summary_title(1), do: "Rule not saved. Fix this:"
  defp summary_title(count), do: "Rule not saved. Fix these #{count}:"

  # A duplicate that names a general rule is one the operator can edit here; a
  # collision whose row vanished, or a type 4/5 record, offers no such action.
  defp open_existing_id({:duplicate, %{id: id}}), do: id
  defp open_existing_id(_error), do: nil

  defp form_error_title(:busy), do: "Rule not saved"
  defp form_error_title(:forbidden), do: "Rule not saved"

  defp form_error_title({:duplicate, _collision} = error) do
    if in_seat_duplicate?(error),
      do: "A stay-on-board record already uses these trips",
      else: "This connection already has a rule"
  end

  defp form_error_text(:busy) do
    "The server didn’t respond. Nothing was changed and your entries are still here."
  end

  defp form_error_text(:forbidden) do
    "You no longer have permission to edit transfer rules. Your entries are still here."
  end

  defp form_error_text({:duplicate, _collision} = error) do
    if in_seat_duplicate?(error) do
      "Stay-on-board records are set in Blocks, and a transfer rule can’t repeat one of them."
    else
      "A rule already covers these stops and services. Edit it instead of adding a second one."
    end
  end

  # A duplicate names the colliding row's view: a type 4/5 record cannot be
  # edited here (R1), and a collision whose row vanished is offered the general
  # message, because that is where a second rule would be created.
  defp in_seat_duplicate?({:duplicate, %{transfer_type: type}}) when type in 4..5, do: true
  defp in_seat_duplicate?(_error), do: false

  # The rejected save's problems, in the order the fields appear, each linking to its
  # field. Only a submit that was refused has them: live validation, which is not a
  # rejection, keeps its errors inline.
  defp summary_failures(%{form: %{action: :insert} = form}) do
    [
      {:from_stop_id, "Riders arrive at", "#transfer_from_stop_id_text_input"},
      {:to_stop_id, "Riders board at", "#transfer_to_stop_id_text_input"},
      {:from_route_id, "Arriving route", "#transfer-from-route"},
      {:to_route_id, "Departing route", "#transfer-to-route"},
      {:transfer_type, "What should happen", "#transfer-type-1"},
      {:min_transfer_time, "Minimum time", "#transfer-min-time"}
    ]
    |> Enum.flat_map(fn {field, label, href} ->
      case field_errors(form, field) do
        [] -> []
        errors -> [%{href: href, msg: "#{label}: #{Enum.join(errors, " ")}"}]
      end
    end)
  end

  defp summary_failures(_editor), do: []

  # One step of the form: a numbered mark and a question, with an optional line of
  # help. The number is decoration, so it is hidden from a screen reader; the
  # question is the heading.
  attr :id, :string, required: true
  attr :number, :integer, required: true
  attr :title, :string, required: true
  slot :inner_block

  defp step_head(assigns) do
    ~H"""
    <div class="flex items-start gap-3">
      <span
        aria-hidden="true"
        class="mt-0.5 flex size-6 shrink-0 items-center justify-center rounded-full bg-canvas text-[13px] font-bold text-strong"
      >
        {@number}
      </span>
      <div>
        <h3 id={@id} class="text-base font-bold text-strong">{@title}</h3>
        <p :if={@inner_block != []} class="mt-0.5 text-[13px] text-muted">
          {render_slot(@inner_block)}
        </p>
      </div>
    </div>
    """
  end

  # One radio card: a whole-card target with a bold title, one line of what it does,
  # and, for a kind, its GTFS value as muted detail. The checked card takes the
  # selection tint and the focused one an outline, so neither rests on colour alone.
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :checked, :boolean, required: true
  attr :title, :string, required: true
  attr :help, :string, required: true
  attr :detail, :string, default: nil

  defp choice_card(assigns) do
    ~H"""
    <label class="relative flex min-h-11 cursor-pointer gap-3 rounded-card border border-control bg-white px-4 py-3.5 hover:bg-canvas has-[:checked]:border-action has-[:checked]:bg-selection has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus">
      <input
        type="radio"
        id={@id}
        name={@name}
        value={@value}
        checked={@checked}
        class="mt-0.5 size-[18px] shrink-0 accent-action focus-visible:outline-none"
      />
      <span class="min-w-0">
        <span class="block text-sm font-bold text-strong">{@title}</span>
        <span class="mt-1 block text-[13px] leading-relaxed text-default">{@help}</span>
        <span :if={@detail} class="mt-1 block text-[13px] text-muted">{@detail}</span>
      </span>
    </label>
    """
  end

  defp error_class, do: "mt-1 flex items-start gap-1.5 text-[13px] font-semibold text-error-fg"

  # One side of the connection: the stop search, what was chosen, and Pick on map.
  # `LiveSelect` owns the text input and the hidden field, so the label points at the
  # input it renders (its id is the form's field id plus `_text_input`), and the
  # field's own error is rendered beside the search rather than by `<.input>`. The
  # group carries `aria-invalid` because the widget's input cannot, which is also
  # what lets the form's error focus find the first invalid stop.
  attr :side, :atom, required: true, values: [:from, :to]
  attr :label, :string, required: true
  attr :editor, :map, required: true, doc: "the page's editor draft"
  attr :errors, :list, required: true, doc: "the stop field's inline errors for this side"

  defp stop_field(assigns) do
    side = assigns.side
    field = assigns.editor.form[stop_field_name(side)]
    stop = stop_option(assigns.editor, side)

    assigns =
      assigns
      |> assign(:component_id, "transfer-#{side}-stop")
      |> assign(:pick_side, pick_side(side))
      |> assign(:input_id, "#{field.id}_text_input")
      |> assign(:field, field)
      |> assign(:stop_options, stop_option_list(stop))
      |> assign(:hint, stop_hint(stop))
      |> assign(:missing?, missing_option?(stop))
      |> assign(:hint_id, "transfer-#{side}-stop-hint")
      |> assign(:error_id, "transfer-#{side}-stop-error")

    ~H"""
    <div
      role="group"
      aria-labelledby={"#{@input_id}-label"}
      aria-invalid={to_string(@errors != [])}
      data-invalid={to_string(@errors != [])}
      class="transfer-stop-field grid gap-1.5"
    >
      <label id={"#{@input_id}-label"} for={@input_id} class="text-[13px] font-[650] text-default">
        {@label}
      </label>
      <div class="flex flex-wrap items-start gap-2">
        <div class="relative min-w-0 flex-1 basis-[220px]">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-3 top-[13px] z-10 size-5 text-muted"
          />
          <.live_component
            module={LiveSelectComponent}
            id={@component_id}
            field={@field}
            options={@stop_options}
            debounce={200}
            update_min_len={1}
            placeholder="Search stops or stations"
            container_class="relative"
            text_input_class="h-11 w-full rounded-control border border-control bg-white pl-10 pr-3 text-sm text-strong placeholder:text-muted"
            text_input_selected_class="text-strong"
            dropdown_class="absolute inset-x-0 top-full z-50 mt-1 max-h-64 overflow-auto rounded-card border border-subtle bg-white p-1 text-strong shadow-float"
            option_class="flex min-h-11 flex-col justify-center rounded-control px-3 py-1.5 text-sm"
            active_option_class="bg-selection"
            available_option_class="cursor-pointer hover:bg-canvas"
          >
            <:option :let={option}>
              <span class="font-[650] text-strong">{option.label}</span>
              <span :if={Map.get(option, :hint)} class="text-[13px] text-muted">{option.hint}</span>
            </:option>
          </.live_component>
        </div>
        <.button
          id={"transfer-pick-#{@side}"}
          type="button"
          variant="secondary"
          class="min-h-11 shrink-0"
          phx-click="start_pick"
          phx-value-side={@pick_side}
        >
          <.icon name="hero-map-pin" class="size-4" /> Pick on map
        </.button>
      </div>
      <p
        id={@hint_id}
        class={["text-[13px]", if(@missing?, do: "font-semibold text-warning-fg", else: "text-muted")]}
      >
        {@hint}
      </p>
      <p :if={@errors != []} id={@error_id} class={error_class()}>
        <.icon name="hero-exclamation-circle" class="mt-px size-4 shrink-0" />
        {Enum.join(@errors, " ")}
      </p>
    </div>
    """
  end

  # The route the scope asks for on one side: required for "One route to another",
  # optional for the mixed scope. Its options follow that side's stop.
  attr :side, :atom, required: true, values: [:from, :to]
  attr :editor, :map, required: true

  defp route_select(assigns) do
    side = assigns.side
    scope = assigns.editor.scope

    assigns =
      assigns
      |> assign(:route_field, assigns.editor.form[route_field(side)])
      |> assign(:route_label, route_field_label(scope, side))
      |> assign(:route_prompt, route_prompt(scope))
      |> assign(:route_options, route_option_list(assigns.editor, side))

    ~H"""
    <.input
      id={"transfer-#{@side}-route"}
      field={@route_field}
      type="select"
      label={@route_label}
      prompt={@route_prompt}
      options={@route_options}
    />
    """
  end

  # A stored rule may name a trip without a route (an imported rank-3 selector), so
  # the trip select also shows when the draft already holds one; a draft that has
  # neither waits for its route and says so.
  attr :side, :atom, required: true, values: [:from, :to]
  attr :editor, :map, required: true

  defp trip_select(assigns) do
    side = assigns.side
    editor = assigns.editor

    assigns =
      assigns
      |> assign(
        :chosen?,
        not is_nil(draft_field(editor, "#{side}_route_id")) or
          not is_nil(draft_field(editor, "#{side}_trip_id"))
      )
      |> assign(:trip_field, editor.form[trip_field(side)])
      |> assign(:trip_label, trip_field_label(side))
      |> assign(:trip_options, trip_option_list(editor, side))

    ~H"""
    <.input
      :if={@chosen?}
      id={"transfer-#{@side}-trip"}
      field={@trip_field}
      type="select"
      label={@trip_label}
      prompt="Any trip"
      options={@trip_options}
    />
    <div :if={not @chosen?} id={"transfer-#{@side}-trip-hint"} class="grid gap-1.5">
      <span class="text-[13px] font-[650] text-default">{@trip_label}</span>
      <p class="flex min-h-11 items-center rounded-control bg-canvas px-3 text-[13px] text-muted">
        Choose a route to pick one of its trips.
      </p>
    </div>
    """
  end

  @doc """
  Renders the context pane's live preview of the draft.

  It answers the same question the inspector answers for a stored rule — the
  kind, the connection the draft describes, and what the rule would mean for
  riders — from the draft rather than from a row, so the operator sees the effect
  of a change before saving. The sentence is the inspector's own for the draft's
  kind; a draft that does not name both stops asks for them instead, because a
  connection is what the preview is about.

  ## Examples

      <.draft_preview editor={@editor} />
  """
  attr :editor, :map, required: true, doc: "the page's editor draft"

  def draft_preview(assigns) do
    editor = assigns.editor
    from = draft_endpoint(editor, :from)
    to = draft_endpoint(editor, :to)

    assigns =
      assigns
      |> assign(:from, from)
      |> assign(:to, to)
      |> assign(:type, draft_type(editor))
      |> assign(:both_stops?, both_stops?(editor))
      |> assign(:sentence, rule_sentence(draft_type(editor), draft_min_time(editor), from, to))
      |> assign(:heading_class, @heading_class)

    ~H"""
    <div id="transfer-draft-preview" class="px-4 py-5 md:px-6">
      <h3 class="text-sm font-bold text-strong">What riders and trip planners will see</h3>
      <h2 class={[@heading_class, "mt-2 text-[22px]"]}>{type_label(@type)}</h2>
      <%= if @both_stops? do %>
        <p class="mt-1 text-[15px] leading-snug text-default">{@sentence}</p>
        <div class="mt-4">
          <.journey_pair from={@from} to={@to} />
        </div>
      <% else %>
        <p class="mt-1 text-sm text-muted">Choose both stops to preview the connection.</p>
      <% end %>
    </div>
    """
  end

  defp scope_choice(scope) do
    Enum.find(@scope_choices, hd(@scope_choices), &(elem(&1, 0) == to_string(scope)))
  end

  # An unknown scope reads as the first choice, which is also the one the LiveView
  # parses an unknown value to, so the cards always show what the draft applies.
  defp scope_value(scope) do
    {value, _title, _help} = scope_choice(scope)
    value
  end

  # Field errors reach the form only once the editor has been used: `to_form/2`
  # answers a changeset without an action with no errors at all, and the submit
  # path sets `:insert`, so an untouched draft never opens covered in red.
  defp field_errors(form, field), do: Enum.map(live_field(form, field).errors, &translate_error/1)

  # While the operator is still changing the draft (`:validate`), a required field
  # they have not filled in yet is not wrong yet: choosing the first stop must not
  # paint the minimum time red. It reads as an error after a refused save, and a
  # value that is present but invalid shows its error as it is typed.
  defp live_field(%{action: :validate} = form, name) do
    field = form[name]

    if Values.blank?(field.value), do: %{field | errors: []}, else: field
  end

  defp live_field(form, name), do: form[name]

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

  defp draft_field(editor, key) do
    case editor.params[key] do
      value when is_binary(value) -> Values.presence(value)
      _value -> nil
    end
  end

  # The preview reads the draft the way the inspector reads a row: an endpoint with
  # the stop the version resolves, and the selector its route and trip choose.
  defp draft_endpoint(editor, side) do
    route_id = draft_field(editor, "#{side}_route_id")
    trip_id = draft_field(editor, "#{side}_trip_id")
    stop = stop_option(editor, side)

    Map.merge(
      %{
        stop_id: draft_field(editor, "#{side}_stop_id"),
        name: stop && stop.stop_name,
        location_type: stop && stop.location_type,
        platform_code: stop && stop.platform_code,
        top_level: stop && stop.parent_name && %{name: stop.parent_name},
        child_count: (stop && stop.child_count) || 0
      },
      draft_selector(editor, route_id, trip_id)
    )
  end

  defp draft_selector(editor, route_id, trip_id) when is_binary(trip_id) do
    %{selector: {:trip, trip_id}, route: route_id && draft_route(editor, route_id)}
  end

  defp draft_selector(editor, route_id, _trip_id) when is_binary(route_id) do
    %{selector: {:route, route_id}, route: draft_route(editor, route_id)}
  end

  defp draft_selector(_editor, _route_id, _trip_id), do: %{selector: :any, route: nil}

  # The route the select shows, so the preview names the same route.
  defp draft_route(editor, route_id) do
    (editor.options.from_routes ++ editor.options.to_routes)
    |> Enum.find(&(&1.route_id == route_id))
  end

  defp both_stops?(editor) do
    not is_nil(draft_field(editor, "from_stop_id")) and
      not is_nil(draft_field(editor, "to_stop_id"))
  end

  defp stop_field_name(:from), do: :from_stop_id
  defp stop_field_name(:to), do: :to_stop_id

  defp route_field(:from), do: :from_route_id
  defp route_field(:to), do: :to_route_id

  defp trip_field(:from), do: :from_trip_id
  defp trip_field(:to), do: :to_trip_id

  # "One route to another" requires both routes, so each side's select is what the
  # rule needs; the mixed scope may leave either one empty, and says so beside the
  # label rather than in the prompt alone.
  defp route_field_label(:custom, side), do: "#{side_title(side)} route (optional)"
  defp route_field_label(_scope, side), do: "#{side_title(side)} route"

  defp trip_field_label(side), do: "#{side_title(side)} trip (optional)"

  defp side_title(:from), do: "Arriving"
  defp side_title(:to), do: "Departing"

  # A route the operator must choose reads as a requirement; a route they may leave
  # out offers the empty choice as "Any route".
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
  # headsign and its service, with the reason a stored trip is not among the
  # route's own options when there is one (AC-XFER-029). The value the select
  # submits is the trip's own id.
  defp trip_option(trip) do
    base =
      [Map.get(trip, :time), Map.get(trip, :headsign), Map.get(trip, :service_id)]
      |> Enum.map(&Values.presence/1)
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
    [%{label: stop_label(stop), value: stop_id, hint: stop_hint(stop)}]
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
    case Values.presence(name) do
      nil -> stop_id
      name -> name
    end
  end

  @doc """
  Describes what kind of place one stop option is, under its name: a station says
  how many platforms it covers, a platform names its station, and anything else is
  a plain stop. A missing stop is the prompt to choose one.

  ## Examples

      iex> stop_hint(nil)
      "Choose a stop or a whole station from this version."
  """
  def stop_hint(nil), do: @stop_hint_unset
  def stop_hint(%{missing?: true}), do: "Not in this version"

  def stop_hint(%{location_type: 1} = stop) do
    case Map.get(stop, :child_count, 0) do
      0 -> "Station"
      count -> "Station · covers #{count} #{Wording.noun(count, "platform")}"
    end
  end

  def stop_hint(%{platform_code: code, parent_name: parent})
      when is_binary(code) and is_binary(parent),
      do: "Platform #{code} at #{parent}"

  def stop_hint(%{parent_name: parent}) when is_binary(parent), do: "Platform at #{parent}"
  def stop_hint(_stop), do: "Stop"

  # A stop the version no longer holds keeps its stored id in the field, and the
  # LiveView marks the option it builds for it.
  defp missing_option?(%{missing?: true}), do: true
  defp missing_option?(_stop), do: false

  # The map protocol's name for the side a pick session answers.
  defp pick_side(:from), do: "a"
  defp pick_side(:to), do: "b"
end
