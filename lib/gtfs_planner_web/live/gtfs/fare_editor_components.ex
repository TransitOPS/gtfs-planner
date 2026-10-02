defmodule GtfsPlannerWeb.Gtfs.FareEditorComponents do
  @moduledoc """
  The fare editor shell's own pieces: the one header primary each tab carries,
  the two states that replace the tab body while the version's fares are still
  resolving or could not be read, and the Prices tab's fare table, save bar,
  conflict panel and saved note.

  The shell is the page frame every fare tab draws into — the Settings back
  link, the "Fares" heading and its lede, the five tabs and the one primary
  action for the tab — so the parts that decide *what* the header shows live
  here and the tab bodies are added to the LiveView beside them.

  `loading/1` is the first-paint skeleton and `load_error/1` the single
  recovery action: a lost database connection is reported once, with the
  version's saved fares described as untouched, rather than presenting an
  empty workspace as the version's data.

  `fare_table/1` is the Prices tab's grid: one row per fare and one column per
  rider type, a payment-method sub-row for a fare whose methods price
  differently, and an editable price cell each. The cells are read from the
  workspace's own `cells`, `prices` and `media_prices`, so what the grid shows
  is what `Fares.save_prices/2` will be handed; nothing here infers an id from a
  name. Its toolbar carries the older-format lens and the Change prices action,
  the two things that change what the grid means rather than one of its cells.

  The older-format lens tints exactly the cells the projection carries — a
  single ride, the default rider type, the fare's base payment method, and
  charged by a rule of its own — which is what an app that reads only
  `fare_attributes.txt` shows. It is a view of the same prices, never a second
  set of them.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents,
    only: [
      choice_cards: 1,
      drawer_footer: 1,
      drawer_scroll: 1,
      form_error_summary: 1,
      message: 1
    ]

  import GtfsPlannerWeb.RouteWorkspace, only: [badge: 1]

  alias GtfsPlanner.Gtfs.Fares.Identifier
  alias GtfsPlanner.Gtfs.Fares.Money
  alias GtfsPlanner.Gtfs.Fares.Transfers
  alias GtfsPlannerWeb.Components.RouteIdentity

  @doc """
  Renders the fare editor's one header primary for the current tab, or nothing.

  One primary per view, and it follows the tab's own task: Create fare on
  Prices, Add fare rule on Where fares apply and Add transfer rule on
  Transfers. Checks has none — it reports what it finds rather than asking for
  a change — and the Zones tab belongs to the zone workspace.

  The action is disabled until the version's fares have loaded, because a
  create action offered over an empty workspace would write against data the
  operator never saw. Transfers shows its action only once the version holds a
  transfer rule, which is what the prototype does: a version with none has
  nothing to add a rule beside.

  Create fare drops to the secondary variant while `dirty?` is true, because
  the operator's next action is then saving or discarding the prices in front
  of them rather than starting a new fare.

  ## Examples

      <.header_primary active_tab={:prices} ready?={@load_state == :ready} />
  """
  attr :active_tab, :atom, required: true, doc: "the tab this page renders"
  attr :ready?, :boolean, default: false, doc: "whether the version's fares have loaded"
  attr :transfers?, :boolean, default: false, doc: "whether the version holds a transfer rule"
  attr :dirty?, :boolean, default: false, doc: "whether the Prices tab holds unsaved prices"

  attr :prices_ready?,
       :boolean,
       default: true,
       doc: "whether the Prices tab asks a question of its own instead of drawing the grid"

  def header_primary(assigns) do
    ~H"""
    <%= case header_action(@active_tab, @ready?, @transfers?, @dirty?, @prices_ready?) do %>
      <% :none -> %>
      <% {:button, id, label, variant, event} -> %>
        <.button
          id={id}
          class="min-h-11"
          variant={variant}
          disabled={not @ready?}
          phx-click={event}
        >
          <.icon name="hero-plus" class="size-4" /> {label}
        </.button>
    <% end %>
    """
  end

  # The tab's own primary, named once so the label and the id cannot drift from
  # each other. `:none` is a real answer for a tab that offers no action. Only
  # Prices names an event, because the fare drawer is the one primary this page
  # owns; the other two belong to the Where and Transfers tabs, whose drawers
  # arrive in their own steps.
  #
  # Prices has none while the tab is asking its own question — the first-use
  # setup, the fare-free summary or an imported version's read-only view — because
  # each of those carries the one primary that answers it and two primaries on
  # one view is a choice an operator cannot make (AC-43).
  defp header_action(:prices, true, _transfers?, _dirty?, false), do: :none

  defp header_action(:prices, true, _transfers?, dirty?, _ready?),
    do:
      {:button, "create-fare", "Create fare", if(dirty?, do: "secondary", else: "primary"),
       "open_fare_drawer"}

  defp header_action(:where, true, _transfers?, _dirty?, _prices_ready?),
    do: {:button, "add-fare-rule", "Add fare rule", "primary", "open_rule_drawer"}

  defp header_action(:transfers, true, true, _dirty?, _prices_ready?),
    do: {:button, "add-transfer-rule", "Add transfer rule", "primary", "open_transfer_create"}

  defp header_action(_active_tab, _ready?, _transfers?, _dirty?, _prices_ready?), do: :none

  @doc """
  Renders the shell's first-paint skeleton.

  Shown while the connected load is still resolving, so the tab body never
  paints as an unexplained blank region. The block widths mirror the header
  and the first rows of a fare table, which is what the tab shows when it
  arrives.

  ## Examples

      <.loading />
  """
  attr :class, :any, default: nil
  attr :rest, :global

  def loading(assigns) do
    ~H"""
    <div
      id="fare-editor-loading"
      role="status"
      aria-busy="true"
      class={["overflow-clip rounded-card border border-subtle bg-white", @class]}
      {@rest}
    >
      <div class="motion-safe:animate-pulse" aria-hidden="true">
        <div class="flex gap-3 border-b border-subtle px-5 py-4">
          <div class="h-4 w-32 rounded-badge bg-canvas"></div>
          <div class="h-4 w-40 rounded-badge bg-canvas"></div>
          <div class="h-4 w-28 rounded-badge bg-canvas"></div>
          <div class="h-4 w-24 rounded-badge bg-canvas"></div>
        </div>
        <div :for={_row <- 1..5} class="flex items-center gap-4 border-b border-subtle px-5 py-4">
          <div class="h-3.5 w-2/5 rounded-badge bg-canvas"></div>
          <div class="h-3.5 flex-1 rounded-badge bg-canvas"></div>
          <div class="h-3.5 w-20 rounded-badge bg-canvas"></div>
        </div>
      </div>
      <p class="px-5 py-3 text-sm text-muted">Loading fares…</p>
    </div>
    """
  end

  @doc """
  Renders the shell's load-error state with its single recovery action.

  The title names what failed and the body says the saved data is untouched, so
  the operator can retry without doubting the version's fares.

  ## Examples

      <.load_error />
  """
  attr :class, :any, default: nil
  attr :rest, :global

  def load_error(assigns) do
    ~H"""
    <div id="fare-editor-error" class={@class} {@rest}>
      <.message kind="error" title="Fares couldn’t load">
        Nothing you saved is affected. Routes, calendars and stops still open from the menu.
        <:action>
          <.button id="fare-editor-reload" phx-click="reload" class="min-h-11">
            <.icon name="hero-arrow-path" class="size-4" /> Reload fares
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  @doc """
  Renders the Prices tab's fare table: the grid, the older-format lens toggle
  and the keyboard hint under it.

  One card holds the toolbar, the lens legend, the table and the hint, and the
  table is the only thing that scrolls sideways: at 390 px the card's own
  `overflow-x-auto` holds the grid while the page itself never widens.

  `edits` is the operator's unsaved prices keyed by
  `"product|rider|medium"`, exactly as the price cell names the row it writes.
  A cell with no edit shows its stored amount; an edit shows what was typed,
  formatted once `GtfsPlanner.Gtfs.Fares.Money.parse/1` has read it.

  ## Examples

      <.fare_table workspace={@workspace} edits={@price_edits} lens?={@lens?} />
  """
  attr :workspace, :map, required: true
  attr :edits, :map, required: true
  attr :lens?, :boolean, default: false
  attr :carried, :any, default: nil, doc: "the fare ids the older format carries, as a MapSet"

  attr :readonly?, :boolean,
    default: false,
    doc: "the version is unmanaged, so no cell is editable"

  attr :class, :any, default: nil
  attr :rest, :global

  def fare_table(assigns) do
    ~H"""
    <section
      id="fare-table"
      aria-labelledby="fare-table-title"
      class={["overflow-clip rounded-card border border-subtle bg-white", @class]}
      {@rest}
    >
      <div class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-subtle px-4 py-2.5 sm:px-5">
        <div class="min-w-0 flex-1 basis-[220px]">
          <h2 id="fare-table-title" class="font-sans text-base font-bold tracking-normal text-strong">
            Fare table
          </h2>
          <p class="text-[13px] text-muted">
            {counted(length(@workspace.fares), "fare", "fares")} · {counted(
              length(@workspace.riders),
              "rider type",
              "rider types"
            )} · prices in {currency_name(@workspace.currency)}
          </p>
        </div>
        <label class="inline-flex min-h-11 cursor-pointer items-center gap-2 text-sm text-strong">
          <input
            type="checkbox"
            id="fare-lens"
            name="lens"
            checked={@lens?}
            phx-click="toggle_lens"
            class="size-5 accent-[var(--color-action)]"
          /> Show what the older format includes
        </label>
        <.button
          :if={not @readonly?}
          id="change-prices"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="open_change_prices"
        >
          <.icon name="hero-percent-badge" class="size-4" /> Change prices
        </.button>
      </div>

      <p
        :if={@lens?}
        id="fare-lens-note"
        class="flex flex-wrap items-center gap-x-4 gap-y-1 border-b border-subtle bg-white px-4 py-2 text-[13px] text-default sm:px-5"
      >
        <span class="inline-flex items-center gap-2">
          <span class="inline-block h-3 w-5 rounded-badge bg-soft ring-1 ring-cyan-300"></span>
          In both formats: the only prices Google Maps shows
        </span>
        <span class="inline-flex items-center gap-2">
          <span class="inline-block h-3 w-5 rounded-badge bg-canvas opacity-60 ring-1 ring-subtle">
          </span>
          Newer format only
        </span>
      </p>

      <div class="relative overflow-x-auto">
        <table class="w-full border-collapse text-sm">
          <caption class="sr-only">
            Each fare's price for every rider type. Type a price and press Tab to move to the next one.
          </caption>
          <thead>
            <tr>
              <th
                scope="col"
                class="min-w-[340px] border-b border-subtle bg-canvas px-4 py-2 text-left align-bottom text-[13px] font-semibold text-strong"
              >
                Fare
              </th>
              <th
                :for={rider <- @workspace.riders}
                scope="col"
                class="w-[168px] min-w-[140px] border-b border-subtle bg-canvas py-2 pl-1 pr-4 align-bottom"
              >
                <div class="flex items-end justify-end gap-0.5">
                  <.button
                    :if={not @readonly?}
                    id={"rider-edit-#{rider.rider_category_id}"}
                    type="button"
                    variant="quiet"
                    class="min-h-11 min-w-11 -mb-1.5 px-1"
                    phx-click="open_rider_drawer"
                    phx-value-rider_category_id={rider.rider_category_id}
                    phx-value-opener_id={"rider-edit-#{rider.rider_category_id}"}
                    aria-label={"Edit rider type #{rider.name}"}
                    title="Edit rider type"
                  >
                    <.icon name="hero-pencil-square" class="size-4" />
                  </.button>
                  <div class="min-w-0 text-right">
                    <span class="block text-[13px] font-semibold leading-snug text-strong">
                      {rider.name}
                    </span>
                    <span class="block text-[12px] font-normal text-muted">
                      {if(rider.default?, do: "Shown first", else: " ")}
                    </span>
                  </div>
                </div>
              </th>
              <th class="w-[1%] border-b border-subtle bg-canvas px-2 py-1 text-right align-bottom">
                <.button
                  :if={not @readonly?}
                  id="create-rider"
                  type="button"
                  variant="quiet"
                  class="min-h-11 px-2 whitespace-nowrap"
                  phx-click="open_rider_drawer"
                  phx-value-opener_id="create-rider"
                  aria-label="Create rider type"
                >
                  <.icon name="hero-plus" class="size-4" /> Rider type
                </.button>
              </th>
            </tr>
          </thead>
          <tbody>
            <%= for group <- fare_groups(@workspace.fares) do %>
              <tr>
                <th
                  colspan={length(@workspace.riders) + 2}
                  scope="colgroup"
                  class="border-b border-subtle bg-white px-4 pb-1.5 pt-4 text-left text-[13px] font-bold text-strong"
                >
                  {group.label}
                  <span class="font-normal text-muted">· {group.help}</span>
                </th>
              </tr>
              <%= for fare <- group.fares do %>
                <tr class="hover:bg-canvas/60">
                  <th
                    scope="row"
                    class="border-b border-subtle px-4 py-2 text-left align-top font-normal"
                  >
                    <button
                      :if={not @readonly?}
                      type="button"
                      id={"fare-open-#{fare_slug(fare)}"}
                      phx-click="open_fare_drawer"
                      phx-value-fare_product_id={List.first(fare.product_ids)}
                      phx-value-opener_id={"fare-open-#{fare_slug(fare)}"}
                      class="group/name block min-h-11 w-full text-left"
                    >
                      <span class="text-sm font-bold text-strong underline decoration-subtle underline-offset-4 group-hover/name:decoration-action">
                        {fare.name}
                      </span>
                      <span class="block text-[13px] font-normal text-default">
                        {fare_where_text(fare, @workspace)}
                      </span>
                    </button>
                    <span :if={@readonly?} class="block">
                      <span class="block text-sm font-bold text-strong">{fare.name}</span>
                      <span class="block text-[13px] font-normal text-default">
                        {fare_where_text(fare, @workspace)}
                      </span>
                    </span>
                    <span
                      :if={@readonly? or length(fare.media) < length(@workspace.media)}
                      class="block text-[12px] text-muted"
                    >
                      {fare_pay_text(fare, @workspace)}
                    </span>
                  </th>
                  <%= for rider <- @workspace.riders do %>
                    <td class="border-b border-subtle p-1">
                      <.price_cell
                        fare={fare}
                        rider={rider}
                        medium_id={nil}
                        medium_name={nil}
                        workspace={@workspace}
                        edits={@edits}
                        lens?={@lens?}
                        carried={@carried}
                        readonly?={@readonly?}
                      />
                    </td>
                  <% end %>
                  <td class="border-b border-subtle"></td>
                </tr>
                <tr :for={medium_id <- sub_row_media(fare)}>
                  <th
                    scope="row"
                    class="border-b border-subtle py-1 pl-8 pr-4 text-left text-[13px] font-normal text-default"
                  >
                    <.icon name="hero-chevron-right" class="inline size-3.5 -mt-0.5 text-muted" />
                    In the {medium_name(@workspace, medium_id)}
                  </th>
                  <%= for rider <- @workspace.riders do %>
                    <td class="border-b border-subtle p-1">
                      <.price_cell
                        fare={fare}
                        rider={rider}
                        medium_id={medium_id}
                        medium_name={medium_name(@workspace, medium_id)}
                        workspace={@workspace}
                        edits={@edits}
                        lens?={@lens?}
                        carried={@carried}
                        readonly?={@readonly?}
                      />
                    </td>
                  <% end %>
                  <td class="border-b border-subtle"></td>
                </tr>
              <% end %>
            <% end %>
          </tbody>
        </table>
      </div>

      <p :if={not @readonly?} class="px-4 py-3 text-[13px] text-muted sm:px-5">
        Type a price and press Tab to move to the next one. Enter
        <b class="font-semibold text-default">Free</b>
        for no charge. Leave a price blank when that rider
        type can’t buy the fare.
      </p>
    </section>
    """
  end

  @doc """
  Renders one editable price cell.

  The cell is the grid's smallest writable unit. Its id names the fare and the
  rider — `price-local_ride-adult` — with the payment method appended on a
  sub-row, and its `name` is the `fare_product_id`/rider/medium triple
  `Fares.save_prices/2` writes the cell by.

  A cell with an unsaved edit is tinted the warning ground; one whose text
  `Fares.Money.parse/1` refuses keeps exactly what was typed and is marked
  invalid, because a mistyped price must never be read as a blank one.
  """
  attr :fare, :map, required: true
  attr :rider, :map, required: true

  attr :medium_id, :any,
    default: nil,
    doc: "the payment method this cell is for, or nil on the fare's own row"

  attr :medium_name, :any, default: nil, doc: "that method's name, for the cell's label"
  attr :workspace, :map, required: true
  attr :edits, :map, required: true
  attr :lens?, :boolean, default: false
  attr :carried, :any, default: nil, doc: "the fare ids the older format carries, as a MapSet"
  attr :readonly?, :boolean, default: false

  def price_cell(assigns) do
    ~H"""
    <div
      class={["relative", lens_class(@lens?, v1_cell?(@fare, @rider, @medium_id, @carried))]}
      data-lens={lens_state(@lens?, v1_cell?(@fare, @rider, @medium_id, @carried))}
    >
      <span
        :if={@readonly?}
        id={cell_id(@fare, @rider, @medium_id)}
        class="flex h-11 w-full min-w-[88px] items-center justify-end px-3 text-sm text-strong"
      >
        {stored_cell_text(@fare, @rider, @medium_id, @workspace)}
      </span>
      <input
        :if={not @readonly?}
        type="text"
        id={cell_id(@fare, @rider, @medium_id)}
        name={"price[#{cell_key(@fare, @rider, @medium_id)}]"}
        value={cell_text(@fare, @rider, @medium_id, @workspace, @edits)}
        placeholder="Not sold"
        aria-label={cell_label(@fare, @rider, @medium_name)}
        aria-invalid={cell_invalid?(@fare, @rider, @medium_id, @edits) && "true"}
        title={cell_title(@fare, @rider, @medium_id, @workspace, @edits)}
        class={[
          "h-11 w-full min-w-[88px] rounded-[6px] border border-transparent bg-transparent px-3 text-sm text-strong",
          "placeholder:font-normal placeholder:text-muted hover:border-[var(--color-control)] hover:bg-white",
          "focus-visible:bg-white focus-visible:outline-2 focus-visible:outline-offset-[-1px]",
          "focus-visible:outline-[var(--color-focus)]",
          cell_changed?(@fare, @rider, @medium_id, @edits) &&
            "border-[var(--color-warning-line)] bg-warning-bg text-warning-fg shadow-[inset_0_-2px_0_var(--color-warning-line)]",
          cell_invalid?(@fare, @rider, @medium_id, @edits) &&
            "shadow-[inset_0_0_0_2px_var(--color-error-fg)]"
        ]}
      />
    </div>
    """
  end

  @doc """
  Renders the sticky save bar for the operator's unsaved prices.

  The bar appears only while a price is unsaved, and says what is unsaved, which
  saved journeys the draft would move and what saving means for the version.
  Save is `aria-disabled` — rather than removed — while a price is unreadable
  or a conflict is unresolved, because the operator can see the action they
  cannot take yet and why the line above it says so.

  ## Examples

      <.price_save_bar
        workspace={@workspace}
        edits={@price_edits}
        journeys={@affected_journeys}
        blocked?={blocked?}
        blocking_reason={blocking_reason}
        version_name={@current_gtfs_version.name}
      />
  """
  attr :workspace, :map, required: true
  attr :edits, :map, required: true
  attr :journeys, :list, default: []
  attr :blocked?, :boolean, default: false
  attr :blocking_reason, :string, default: nil
  attr :version_name, :string, default: nil
  attr :published?, :boolean, default: true

  def price_save_bar(assigns) do
    ~H"""
    <div
      id="price-save-bar"
      class="sticky bottom-0 z-20 mt-4 flex flex-wrap items-center gap-x-4 gap-y-2 rounded-b-card border-t border-action bg-white px-4 py-3 shadow-[0_-8px_24px_#0a13300d] sm:px-5"
    >
      <div class="min-w-0 flex-1 basis-[320px]">
        <p class="text-sm font-bold text-strong">
          {@blocking_reason || "Unsaved: #{counted(map_size(@edits), "price", "prices")}"}
        </p>
        <p :if={edit_summary(@workspace, @edits) != ""} class="truncate text-[13px] text-muted">
          {edit_summary(@workspace, @edits)}
        </p>
        <p
          :if={@journeys != []}
          class="text-[13px] font-semibold text-warning-fg"
        >
          <.icon name="hero-exclamation-triangle" class="inline size-4 -mt-0.5" />
          {counted(length(@journeys), "saved journey change", "saved journeys change")} price: {journey_summary(
            @workspace,
            @journeys
          )}
        </p>
        <p class="text-[13px] text-muted">
          Changes apply to {version_phrase(@version_name, @published?)} as soon as you save.
        </p>
      </div>
      <.button id="discard-prices" variant="secondary" class="min-h-11" phx-click="discard_prices">
        Discard changes
      </.button>
      <.button
        id="save-prices"
        class="min-h-11"
        phx-click="save_prices"
        aria-disabled={to_string(@blocked?)}
      >
        Save {counted(map_size(@edits), "price", "prices")}
      </.button>
    </div>
    """
  end

  @doc """
  Renders the conflict panel a stale save raises.

  Nothing is written when another operator has changed a cell the operator
  reviewed, so the panel names who changed it and when from the version's own
  change log, keeps every entry, and asks which price to keep for each cell
  both of them changed. A cell only one of them changed is stated rather than
  asked about.

  ## Examples

      <.fares_conflict conflict={@price_conflict} workspace={@workspace} />
  """
  attr :conflict, :map, required: true
  attr :workspace, :map, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def fares_conflict(assigns) do
    ~H"""
    <div
      id="fares-conflict"
      role="alert"
      tabindex="-1"
      class={["rounded-card bg-warning-bg px-4 py-3 text-warning-fg", @class]}
      {@rest}
    >
      <p class="flex items-center gap-2 text-sm font-bold">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        {@conflict.actor} saved prices at {conflict_time(@conflict)}, while you were editing
      </p>
      <p class="mt-0.5 text-sm">
        Nothing was saved. Your entries are kept. Prices only one of you changed are kept as they are.
        Choose which {counted(length(@conflict.cells), "price", "prices")} to keep, then save.
      </p>
      <div class="mt-3 overflow-x-auto rounded-card border border-[var(--color-warning-line)] bg-white text-default">
        <table class="w-full text-sm">
          <thead>
            <tr class="bg-canvas text-left text-[13px]">
              <th scope="col" class="px-3 py-2 font-semibold text-strong">Price</th>
              <th scope="col" class="px-3 py-2 text-right font-semibold text-strong">Your change</th>
              <th scope="col" class="px-3 py-2 text-right font-semibold text-strong">
                {@conflict.actor}’s change
              </th>
              <th scope="col" class="px-3 py-2 font-semibold text-strong">Result</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={cell <- @conflict.cells} class="border-t border-subtle">
              <th scope="row" class="px-3 py-2 text-left font-normal text-strong">
                {cell.label}
              </th>
              <td class="px-3 text-right tabular-nums">{cell.mine_text}</td>
              <td class="px-3 text-right tabular-nums">{cell.theirs_text}</td>
              <td class="px-3">
                <div :if={is_nil(cell.choice)} class="flex flex-wrap gap-x-4">
                  <label class="flex min-h-11 cursor-pointer items-center gap-2">
                    <input
                      type="radio"
                      name={"conflict[#{cell.key}]"}
                      value="mine"
                      id={"conflict-#{cell.key}-mine"}
                      phx-click="choose_conflict"
                      phx-value-key={cell.key}
                      phx-value-choice="mine"
                      class="size-4 accent-[var(--color-action)]"
                    /> Keep mine
                  </label>
                  <label class="flex min-h-11 cursor-pointer items-center gap-2">
                    <input
                      type="radio"
                      name={"conflict[#{cell.key}]"}
                      value="theirs"
                      id={"conflict-#{cell.key}-theirs"}
                      phx-click="choose_conflict"
                      phx-value-key={cell.key}
                      phx-value-choice="theirs"
                      class="size-4 accent-[var(--color-action)]"
                    /> Keep {@conflict.actor}’s
                  </label>
                </div>
                <p :if={cell.choice == :theirs} class="text-[13px]">
                  {@conflict.actor}’s is kept
                </p>
                <p :if={cell.choice == :mine} class="text-[13px]">Yours is kept</p>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  @doc """
  Renders the saved note bar, with Undo while the last change can be reversed.

  The note is a polite status rather than an alert: a price that saved is an
  outcome, not a failure. `phx-mounted` moves focus here after a save, so the
  operator lands on what happened instead of on a grid whose values moved under
  the cursor.

  ## Examples

      <.fare_note note={@price_note} />
  """
  attr :note, :map, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def fare_note(assigns) do
    ~H"""
    <div
      :if={@note}
      id="fare-note"
      role="status"
      tabindex="-1"
      phx-mounted={JS.focus()}
      class={[
        "flex flex-wrap items-center gap-x-4 gap-y-1 rounded-card px-4 py-1.5 #{note_tone(@note)}",
        @class
      ]}
      {@rest}
    >
      <.icon name={note_icon(@note)} class="size-5" />
      <p class="min-w-0 flex-1 basis-[240px] py-2 text-sm font-bold">{@note.text}</p>
      <.button
        :if={@note[:undo]}
        id="undo-prices"
        variant="quiet"
        class="min-h-11"
        phx-click="undo_prices"
      >
        <.icon name="hero-arrow-uturn-left" class="size-4" /> Undo
      </.button>
    </div>
    """
  end

  @doc """
  Renders the Prices tab's three cards below the grid: the plain-words summary,
  how riders pay, and the recent price changes.

  The summary is worked from the same fares the grid shows, so it cannot
  disagree with it. A version with nothing to say in a card renders the card's
  own empty line rather than an empty box.

  ## Examples

      <.fare_cards workspace={@workspace} />
  """
  attr :workspace, :map, required: true
  attr :history, :list, default: []
  attr :class, :any, default: nil

  def fare_cards(assigns) do
    ~H"""
    <div class={["grid gap-4", @class]}>
      <section
        id="fare-summary-card"
        aria-labelledby="fare-summary-title"
        class="overflow-clip rounded-card border border-subtle bg-white"
      >
        <div class="flex flex-wrap items-start gap-x-6 gap-y-2 px-4 py-3 sm:px-5">
          <div class="min-w-0 flex-1 basis-[420px]">
            <h2
              id="fare-summary-title"
              class="font-sans text-base font-bold tracking-normal text-strong"
            >
              Fares in plain words
            </h2>
            <ul :if={summary_lines(@workspace) != []} class="mt-1 grid gap-0.5 text-sm text-default">
              <li :for={line <- summary_lines(@workspace)}>{line}</li>
            </ul>
            <p :if={summary_lines(@workspace) == []} class="mt-1 text-sm text-muted">
              No single ride is priced by a rule yet, so there is nothing to summarize.
            </p>
          </div>
        </div>
      </section>

      <div class="grid gap-4 lg:grid-cols-2">
        <section
          id="fare-payment-card"
          aria-labelledby="fare-payment-title"
          class="overflow-clip rounded-card border border-subtle bg-white"
        >
          <div class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-subtle px-4 py-3 sm:px-5">
            <div class="min-w-0 flex-1">
              <h2
                id="fare-payment-title"
                class="font-sans text-base font-bold tracking-normal text-strong"
              >
                How riders pay
              </h2>
              <p class="text-[13px] text-muted">
                Trip planners show these as ways to pay. A fare can cost less with one of them.
              </p>
            </div>
            <.button
              id="create-media"
              type="button"
              variant="quiet"
              class="min-h-11 max-sm:w-full"
              phx-click="open_media_drawer"
              phx-value-opener_id="create-media"
            >
              <.icon name="hero-plus" class="size-4" /> Create payment method
            </.button>
          </div>
          <ul id="fare-payment-list">
            <li
              :for={medium <- @workspace.media}
              class="flex flex-wrap items-center gap-x-4 gap-y-1 border-b border-subtle px-4 py-2 last:border-b-0 sm:px-5"
            >
              <button
                type="button"
                id={"media-open-#{medium.fare_media_id}"}
                phx-click="open_media_drawer"
                phx-value-fare_media_id={medium.fare_media_id}
                phx-value-opener_id={"media-open-#{medium.fare_media_id}"}
                class="min-h-11 text-left text-sm font-bold text-strong underline decoration-subtle underline-offset-4 hover:decoration-action"
              >
                {medium.name}
              </button>
              <span class="text-[13px] text-muted">{media_type_name(medium.fare_media_type)}</span>
              <span class="ml-auto text-[13px] tabular-nums text-default">
                Accepted for {counted(
                  accepted_count(@workspace, medium.fare_media_id),
                  "fare",
                  "fares"
                )}
              </span>
            </li>
          </ul>
          <p :if={@workspace.media == []} class="px-4 py-3 text-[13px] text-muted sm:px-5">
            This version has no payment method yet.
          </p>
        </section>

        <section
          id="fare-history-card"
          aria-labelledby="fare-history-title"
          class="overflow-clip rounded-card border border-subtle bg-white"
        >
          <div class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-subtle px-4 py-3 sm:px-5">
            <div class="min-w-0 flex-1">
              <h2
                id="fare-history-title"
                class="font-sans text-base font-bold tracking-normal text-strong"
              >
                Recent price changes
              </h2>
              <p class="text-[13px] text-muted">
                Kept for this version. Undo reverses the latest change.
              </p>
            </div>
          </div>
          <ul :if={@history != []}>
            <li
              :for={entry <- @history}
              class="border-b border-subtle px-4 py-2.5 last:border-b-0 sm:px-5"
            >
              <p class="text-sm text-strong">{entry.summary}</p>
              <p class="text-[13px] text-muted">
                {entry.actor_email} · {history_time(entry.inserted_at)}
              </p>
            </li>
          </ul>
          <p :if={@history == []} class="px-4 py-3 text-[13px] text-muted sm:px-5">
            Nothing has changed on this version’s fares yet.
          </p>
        </section>
      </div>
    </div>
    """
  end

  # -- Cells ------------------------------------------------------------------

  # One cell is the `fare_products` row the grid writes, named by the three
  # values that key it. The fare's own product id is the one that row carries,
  # read from the workspace rather than derived from the fare's name. A row that
  # names no payment method is the fare's base method, which is how GTFS states
  # "one price, any payment method", so it is matched against the fare's own row.
  defp find_cell(fare, rider, medium_id) do
    Enum.find(fare.cells, fn cell ->
      cell.rider_category_id == rider.rider_category_id and
        (cell.fare_media_id || fare.base_media_id) == (medium_id || fare.base_media_id)
    end)
  end

  defp cell_product_id(fare, rider, medium_id) do
    case find_cell(fare, rider, medium_id) do
      nil -> List.first(fare.product_ids)
      cell -> cell.fare_product_id
    end
  end

  # A cell is keyed by the `fare_products` row it writes, and that row's own
  # payment method is part of the key: a fare's main row draws the method whose
  # amounts it shows, and the write has to name the same method the stored row
  # does or the fence reads the row as missing.
  defp cell_key(fare, rider, medium_id) do
    medium = cell_medium(fare, rider, medium_id)

    Enum.join(
      [cell_product_id(fare, rider, medium_id), rider.rider_category_id, medium || ""],
      "|"
    )
  end

  # The payment method the write names for this cell: the stored row's own
  # method, or the one the grid drew when the fare is not yet sold to that rider.
  defp cell_medium(fare, rider, medium_id) do
    case find_cell(fare, rider, medium_id) do
      nil -> medium_id || fare.base_media_id
      cell -> cell.fare_media_id || fare.base_media_id
    end
  end

  # A cell's DOM id names the fare and the rider — "price-local_ride-adult" — the
  # way the reference does, with the payment method appended on a sub-row. A fare
  # is one name in this editor, so the fare's own slug identifies the row; the
  # input's `name` carries the `fare_product_id` the write needs instead, which
  # is read from the workspace and never derived from the name.
  defp cell_id(fare, rider, medium_id) do
    case medium_id do
      nil -> "price-#{fare_slug(fare)}-#{rider.rider_category_id}"
      medium -> "price-#{fare_slug(fare)}-#{rider.rider_category_id}-#{medium}"
    end
  end

  defp fare_slug(fare) do
    case fare.name do
      name when is_binary(name) ->
        case Identifier.normalize(name) do
          "" -> List.first(fare.product_ids)
          slug -> slug
        end

      _other ->
        List.first(fare.product_ids)
    end
  end

  defp cell_label(fare, rider, medium_name) do
    "#{fare.name}#{medium_name && ", in the #{medium_name}"}, #{rider.name} price"
  end

  # What the cell reads: an unsaved entry exactly as it was typed when
  # `Fares.Money.parse/1` refuses it, that entry formatted once it is readable,
  # and otherwise the stored amount — a blank cell for a fare this rider type
  # cannot buy.
  defp cell_text(fare, rider, medium_id, workspace, edits) do
    case Map.get(edits, cell_key(fare, rider, medium_id)) do
      nil -> Money.format(stored_amount(fare, rider, medium_id), workspace.currency) || ""
      edit -> cell_edit_text(edit, workspace.currency)
    end
  end

  defp cell_edit_text(%{invalid?: true, text: text}, _currency), do: text
  defp cell_edit_text(%{amount: amount}, currency), do: Money.format(amount, currency) || ""

  # A stored cell's own text: what the version holds, formatted the way the grid
  # formats an unchanged cell, so a read-only view and the grid never disagree
  # about a price.
  defp stored_cell_text(fare, rider, medium_id, workspace) do
    case stored_amount(fare, rider, medium_id) do
      nil -> "Not sold"
      amount -> Money.format(amount, workspace.currency)
    end
  end

  defp cell_changed?(fare, rider, medium_id, edits) do
    Map.has_key?(edits, cell_key(fare, rider, medium_id))
  end

  defp cell_invalid?(fare, rider, medium_id, edits) do
    case Map.get(edits, cell_key(fare, rider, medium_id)) do
      %{invalid?: true} -> true
      _other -> false
    end
  end

  defp cell_title(fare, rider, medium_id, workspace, edits) do
    case Map.get(edits, cell_key(fare, rider, medium_id)) do
      nil ->
        nil

      edit ->
        "Was #{Money.format(stored_amount(fare, rider, medium_id), workspace.currency) || "not sold"}"
        |> then(&"#{&1}, now #{cell_edit_text(edit, workspace.currency)}")
    end
  end

  defp stored_amount(fare, rider, medium_id) do
    case medium_id do
      nil -> Map.get(fare.prices, rider.rider_category_id)
      medium -> get_in(fare.media_prices, [medium, rider.rider_category_id])
    end
  end

  # The lens tints exactly what the older format carries: one price per fare,
  # for the default rider type, on the fare's own row rather than a
  # payment-method sub-row, and only for a fare `Fares.Projection` derives a
  # `fare_attributes` row for. Reading the projection's own carried ids is what
  # keeps the tint and the export from disagreeing about which fares those are.
  defp v1_cell?(_fare, _rider, _medium_id, nil), do: false

  defp v1_cell?(fare, rider, medium_id, carried) do
    rider.default? and is_nil(medium_id) and MapSet.member?(carried, fare_slug(fare))
  end

  defp lens_class(true, true), do: "bg-soft"
  defp lens_class(true, false), do: "opacity-60"
  defp lens_class(false, _v1?), do: ""

  # Which half of the lens a cell falls in, on the cell's own wrapper. The
  # classes above carry the tint; this says which one applied, so the state is
  # assertable without reading a utility class back out of the markup.
  defp lens_state(false, _v1?), do: "off"
  defp lens_state(true, true), do: "in"
  defp lens_state(true, false), do: "out"

  # -- Save bar ---------------------------------------------------------------

  # The unsaved cells, in the grid's own order, as "Fare · Rider $old → $new".
  # `grid_cells/2` walks the rows the table actually draws, so the summary cannot
  # name a cell the operator cannot see.
  defp edit_summary(workspace, edits) do
    workspace.fares
    |> Enum.flat_map(&grid_cells(workspace, &1))
    |> Enum.filter(fn {fare, rider, medium_id} ->
      Map.has_key?(edits, cell_key(fare, rider, medium_id))
    end)
    |> Enum.map(fn {fare, rider, medium_id} ->
      edit = Map.fetch!(edits, cell_key(fare, rider, medium_id))
      medium = if is_nil(medium_id), do: "", else: " in the #{medium_name(workspace, medium_id)}"

      "#{fare.name}#{medium} · #{rider.name} " <>
        "#{stored_text(fare, rider, medium_id, workspace)} → #{cell_edit_text(edit, workspace.currency)}"
    end)
    |> summarize()
  end

  defp summarize([]), do: ""

  defp summarize(lines) do
    case lines do
      [one, two] -> "#{one} · #{two}"
      [one] -> one
      [one, two | rest] -> "#{one} · #{two} · and #{length(rest)} more"
    end
  end

  defp stored_text(fare, rider, medium_id, workspace) do
    Money.format(stored_amount(fare, rider, medium_id), workspace.currency) || "not sold"
  end

  defp journey_summary(workspace, journeys) do
    Enum.map_join(journeys, "; ", fn journey ->
      "#{journey.name} #{Money.format(journey.expected, workspace.currency) || "$0.00"} → #{Money.format(journey.now, workspace.currency) || "$0.00"}"
    end)
  end

  defp version_phrase(nil, _published?), do: "this version"
  defp version_phrase(name, true), do: "#{name} service, a published version"
  defp version_phrase(name, false), do: "#{name} service"

  # The Change prices dialog's status line says when riders see the new prices,
  # which is the version's own publication state rather than a promise about
  # when this page is next exported.
  defp export_phrase(nil, _published?), do: "Nothing changes until you update."

  defp export_phrase(name, true),
    do: "#{name} service is published: riders see new prices at your next export."

  defp export_phrase(name, false),
    do: "#{name} service is not published yet, so riders see new prices when you publish it."

  defp note_tone(%{tone: :neutral}), do: "bg-canvas text-default"
  defp note_tone(_note), do: "bg-soft text-info-fg"

  defp note_icon(%{tone: :neutral}), do: "hero-arrow-uturn-left"
  defp note_icon(_note), do: "hero-check-circle"

  defp conflict_time(%{at: at}) when is_struct(at, DateTime),
    do: Calendar.strftime(at, "%b %-d, %-I:%M %p")

  defp conflict_time(_conflict), do: "just now"

  # -- Grid text --------------------------------------------------------------

  # The fare's charging conditions in one line: which route groups charge it
  # and where between them. A fare no rule charges says so rather than claiming
  # a place it does not have.
  defp fare_where_text(%{kind: "pass"} = fare, workspace) do
    case fare.accepted_network_ids do
      [] ->
        "Not accepted on any route group yet"

      groups ->
        "Unlimited rides on #{Enum.map_join(groups, " and ", &group_name(workspace, &1))}"
    end
  end

  defp fare_where_text(fare, workspace) do
    case fare.rules do
      [] ->
        "No fare rule charges it yet"

      rules ->
        groups =
          rules |> Enum.map(& &1.network_id) |> Enum.uniq() |> Enum.sort()

        named = Enum.map_join(groups, ", ", &group_name(workspace, &1))
        condition = rule_condition(rules, workspace)
        "#{named} · #{condition}"
    end
  end

  defp rule_condition(rules, workspace) do
    cond do
      Enum.all?(rules, &(blank_area?(&1.from_area_id) and blank_area?(&1.to_area_id))) ->
        "any stops"

      Enum.all?(rules, &(&1.from_area_id == &1.to_area_id)) ->
        "within one zone"

      true ->
        rules
        |> Enum.map(fn rule ->
          "#{zone_name(workspace, rule.from_area_id)} ↔ #{zone_name(workspace, rule.to_area_id)}"
        end)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.join(", ")
    end
  end

  defp blank_area?(nil), do: true
  defp blank_area?(""), do: true
  defp blank_area?(_area_id), do: false

  defp fare_pay_text(fare, workspace) do
    names = Enum.map(fare.media, &medium_name(workspace, &1)) |> Enum.reject(&(&1 in [nil, ""]))

    case names do
      [] -> "Payment method not recorded"
      [one] -> "#{one} only"
      many -> Enum.join(many, ", ")
    end
  end

  # The plain-words summary. Each line is a fact worked from the same fares the
  # grid shows, so it moves when a price moves and never asserts a price the
  # table does not hold.
  defp summary_lines(%{riders: []}), do: []

  defp summary_lines(workspace) do
    singles = charged_singles(workspace)
    default = Enum.find(workspace.riders, & &1.default?) || List.first(workspace.riders)

    [
      price_range_line(singles, default, workspace),
      other_riders_line(singles, default, workspace),
      transfers_line(workspace),
      passes_line(workspace, default)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp charged_singles(workspace) do
    workspace.fares
    |> Enum.filter(&(&1.kind == "single" and &1.rules != []))
    |> Enum.sort_by(&Map.get(&1.prices, "adult"))
  end

  defp price_range_line([], _default, _workspace), do: nil

  defp price_range_line(singles, default, workspace) do
    prices =
      singles
      |> Enum.map(fn fare -> {fare, Map.get(fare.prices, default.rider_category_id)} end)
      |> Enum.reject(fn {_fare, price} -> is_nil(price) end)
      |> Enum.sort_by(fn {_fare, price} -> price end)

    case prices do
      [] ->
        nil

      [{lowest, low}, {highest, high} | _rest] ->
        "A #{lowest.name} costs #{Money.format(low, workspace.currency)} for #{rider_label(default)}. " <>
          if(lowest.name == highest.name,
            do: "",
            else:
              "Other rides cost up to #{Money.format(high, workspace.currency)} (#{highest.name})."
          )

      [{only, price}] ->
        "A #{only.name} costs #{Money.format(price, workspace.currency)} for #{rider_label(default)}."
    end
  end

  defp other_riders_line(singles, default, workspace) do
    parts =
      workspace.riders
      |> Enum.reject(& &1.default?)
      |> Enum.map(&other_rider_part(&1, singles, default, workspace))
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> nil
      _many -> Enum.join(parts, " ")
    end
  end

  defp other_rider_part(rider, singles, default, workspace) do
    ratios =
      singles
      |> Enum.map(fn fare ->
        {Map.get(fare.prices, rider.rider_category_id),
         Map.get(fare.prices, default.rider_category_id), fare}
      end)
      |> Enum.filter(fn {price, adult, _fare} ->
        not is_nil(price) and not is_nil(adult) and Decimal.compare(adult, 0) == :gt
      end)

    cond do
      ratios == [] ->
        nil

      Enum.all?(ratios, fn {price, _adult, _fare} -> Decimal.equal?(price, 0) end) ->
        "#{rider_label(rider)} ride free."

      true ->
        {price, _adult, fare} = hd(ratios)

        "#{rider_label(rider)} riders pay #{Money.format(price, workspace.currency)} for a #{fare.name}."
    end
  end

  defp rider_label(%{name: name}), do: String.downcase(name || "rider")

  # The version's own transfer policy, in one sentence. A leg group is a stored
  # id with no name of its own here, so the sentence states the policy and the
  # window rather than inventing a route group a reader cannot see.
  defp transfers_line(workspace) do
    free =
      Enum.find(workspace.transfers, fn transfer ->
        transfer.from_leg_group_id == transfer.to_leg_group_id and transfer.policy[:pay] == :free
      end)

    cross =
      Enum.any?(workspace.transfers, fn transfer ->
        transfer.from_leg_group_id != transfer.to_leg_group_id and
          transfer.policy[:pay] == :difference
      end)

    case free do
      nil ->
        nil

      %{policy: policy} ->
        "Transfers are free for #{policy.minutes} minutes within a route group" <>
          if(cross,
            do: "; riders who change to another group pay the difference.",
            else: "."
          )
    end
  end

  defp passes_line(workspace, default) do
    passes =
      workspace.fares
      |> Enum.filter(&(&1.kind == "pass"))
      |> Enum.map(fn fare ->
        "#{fare.name} #{Money.format(Map.get(fare.prices, default.rider_category_id), workspace.currency)}"
      end)

    case passes do
      [] -> nil
      many -> "Passes: #{Enum.join(many, ", ")}."
    end
  end

  defp accepted_count(workspace, medium_id) do
    Enum.count(workspace.fares, &(medium_id in &1.media))
  end

  defp history_time(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d, %-I:%M %p")
  defp history_time(_at), do: "just now"

  defp currency_name("USD"), do: "US dollars"
  defp currency_name(code), do: code

  defp rider_name(workspace, rider_id) do
    case Enum.find(workspace.riders, &(&1.rider_category_id == rider_id)) do
      %{name: name} -> name
      nil -> rider_id
    end
  end

  defp medium_name(workspace, medium_id) do
    case Enum.find(workspace.media, &(&1.fare_media_id == medium_id)) do
      %{name: name} -> name
      nil -> medium_id
    end
  end

  defp group_name(workspace, network_id) do
    case Enum.find(workspace.groups, &(&1.network_id == network_id)) do
      %{name: name} -> name
      nil -> network_id
    end
  end

  # The zones a fare's rules name. The workspace's matrices carry the version's
  # own zone names; an area no matrix holds is rendered by its stored id rather
  # than by a made-up name.
  defp zone_name(workspace, area_id) do
    workspace.matrices
    |> Enum.flat_map(& &1.zones)
    |> Enum.find(&(&1.area_id == area_id))
    |> case do
      %{name: name} -> name
      nil -> area_id
    end
  end

  # Every cell the table draws for one fare: the fare's own row for each rider,
  # then one row per payment method that prices differently.
  defp grid_cells(workspace, fare) do
    main =
      Enum.map(workspace.riders, fn rider -> {fare, rider, nil} end)

    sub =
      for medium_id <- sub_row_media(fare),
          rider <- workspace.riders,
          do: {fare, rider, medium_id}

    main ++ sub
  end

  # The payment methods a fare draws a sub-row for: those whose amounts differ
  # from the fare's base-method row, which is exactly `media_prices`.
  defp sub_row_media(fare) do
    fare.media_prices |> Map.keys() |> Enum.sort()
  end

  defp fare_groups(fares) do
    [
      {"Single rides", "one ride; transfers follow your transfer rules",
       Enum.filter(fares, &(&1.kind == "single"))},
      {"Passes", "unlimited rides on the route groups that accept them",
       Enum.filter(fares, &(&1.kind == "pass"))},
      {"Other fares", "every other kind of fare this version holds",
       Enum.reject(fares, &(&1.kind in ["single", "pass"]))}
    ]
    |> Enum.reject(fn {_label, _help, list} -> list == [] end)
    |> Enum.map(fn {label, help, list} ->
      %{label: label, help: help, fares: list}
    end)
  end

  @media_type_names %{
    0 => "On board",
    1 => "Printed ticket",
    2 => "Phone or online",
    3 => "Contactless card",
    4 => "Mobile app"
  }

  defp media_type_name(nil), do: "Payment method"
  defp media_type_name(type), do: Map.get(@media_type_names, type, "Payment method")

  # A count with its noun, the way the prototype's summary lines read it: "7
  # fares", "1 fare".
  # -- Fare drawer --------------------------------------------------------------

  @doc """
  Renders the fare drawer: one fare as one form, whether it is being created or
  edited.

  `draft` is the LiveView's own draft, built when the drawer opens and rebuilt on
  every change: the fare's name and kind, one price per rider type, a second
  price per rider type for the payment method that differs, the methods it is
  sold on, and the route groups a pass is accepted on. It also carries what the
  last submit found — `failures` for the error summary, `name_error`,
  `price_error`, `media_error` for the fields they name, and `invalid_riders` for
  the price inputs a rider type's unreadable price belongs to.

  Prices are plain inputs named by their rider type and payment method rather
  than `to_form` fields, because they are a grid whose shape is the version's
  own rider types and payment methods rather than a fixed set of columns. The
  name is the one field `to_form` carries, so it renders through `<.input>`.

  ## Examples

      <.fare_drawer
        draft={@fare_draft}
        form={to_form(%{"name" => @fare_draft.name}, as: :fare)}
        workspace={@workspace}
        version_name={@current_gtfs_version.name}
        published?={published?}
        return_focus_id={@fare_return_focus_id}
      />
  """
  attr :draft, :map, required: true
  attr :form, :any, required: true
  attr :workspace, :map, required: true
  attr :version_name, :string, default: nil
  attr :published?, :boolean, default: true
  attr :return_focus_id, :string, default: nil
  attr :pending?, :boolean, default: false

  def fare_drawer(assigns) do
    assigns =
      assigns
      |> assign(:editing?, assigns.draft.key != nil)
      |> assign(:title, fare_drawer_title(assigns.draft))

    ~H"""
    <.drawer
      id="fare-drawer"
      chrome="planner"
      open
      pending={@pending?}
      on_close="close_fare_drawer"
      title={@title}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
      class="max-w-[520px]"
    >
      <:lede>
        Changes apply to {version_phrase(@version_name, @published?)} as soon as you save.
      </:lede>

      <div
        id="fare-drawer-content"
        phx-hook="FormErrorFocus"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.form
          for={@form}
          id="fare-form"
          as={:fare}
          novalidate
          phx-change="validate_fare"
          phx-submit="save_fare"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.form_error_summary
              id="error-summary"
              title={fare_error_summary_title(length(@draft.failures))}
              failures={@draft.failures}
            />

            <.input
              id="fare-name"
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="For example, Local ride"
              errors={List.wrap(@draft.name_error)}
              help="Riders see this name in trip planners, such as “Local ride” or “Day pass”."
              autocomplete="off"
              phx-debounce="300"
            />

            <.choice_cards
              id="fare-kind"
              name="fare[kind]"
              type="radio"
              label="What riders get"
              selected={List.wrap(@draft.kind)}
              options={[
                %{
                  value: "single",
                  label: "Single ride",
                  description: "Pays for one ride. Changes follow your transfer rules."
                },
                %{
                  value: "pass",
                  label: "Pass",
                  description:
                    "Unlimited rides on the route groups you choose. Put the period in the name, such as “Day pass”."
                }
              ]}
            />

            <fieldset id="fare-prices" class="min-w-0">
              <legend class="text-sm font-semibold text-strong">Prices</legend>
              <p class="mt-0.5 text-[13px] text-muted">
                Enter Free for no charge. Leave a price blank when that rider type can’t buy this
                fare.
              </p>
              <p
                :if={@draft.price_error}
                id="fare-prices-error"
                class="mt-1.5 flex items-start gap-1.5 text-[13px] font-semibold text-error-fg"
              >
                <.icon name="hero-exclamation-circle" class="mt-px size-4 shrink-0" />
                <span>{@draft.price_error}</span>
              </p>

              <div class="mt-3 grid grid-cols-[minmax(0,1fr)_120px] gap-3 text-[12px] font-semibold text-muted">
                <span>Rider type</span>
                <span class="text-right">Price</span>
              </div>

              <div class="mt-2 grid gap-3">
                <div
                  :for={rider <- @workspace.riders}
                  class="grid grid-cols-[minmax(0,1fr)_120px] items-center gap-3 border-b border-subtle py-1.5 last:border-b-0"
                >
                  <label for={"fare-price-#{rider.rider_category_id}"} class="text-sm text-strong">
                    {rider.name}
                    <span :if={rider.default?} class="text-[12px] text-muted">· shown first</span>
                  </label>
                  <.fare_price_input
                    id={"fare-price-#{rider.rider_category_id}"}
                    name={"fare[prices][#{rider.rider_category_id}]"}
                    value={Map.get(@draft.prices, rider.rider_category_id, "")}
                    label={"#{rider.name} price"}
                    invalid?={rider.rider_category_id in @draft.invalid_riders}
                  />
                </div>
              </div>

              <.fare_checkbox
                :if={@draft.app_medium}
                id="fare-differ"
                name="fare[differ]"
                value="true"
                checked={@draft.differ?}
                label="Price differs by payment method"
                help="For example a lower price in the app. Blank app prices use the cash price."
              />
            </fieldset>

            <fieldset :if={@draft.differ?} id="fare-app-prices" class="min-w-0">
              <legend class="text-sm font-semibold text-strong">
                Prices in the {medium_name(@workspace, @draft.app_medium)}
              </legend>
              <div class="mt-2 grid gap-3">
                <div
                  :for={rider <- @workspace.riders}
                  class="grid grid-cols-[minmax(0,1fr)_120px] items-center gap-3 border-b border-subtle py-1.5 last:border-b-0"
                >
                  <label
                    for={"fare-app-price-#{rider.rider_category_id}"}
                    class="text-sm text-strong"
                  >
                    {rider.name}
                  </label>
                  <.fare_price_input
                    id={"fare-app-price-#{rider.rider_category_id}"}
                    name={"fare[media_prices][#{@draft.app_medium}][#{rider.rider_category_id}]"}
                    value={Map.get(@draft.app_prices, rider.rider_category_id, "")}
                    placeholder="Same"
                    label={"#{rider.name} price in the #{medium_name(@workspace, @draft.app_medium)}"}
                  />
                </div>
              </div>
            </fieldset>

            <fieldset id="fare-media" class="min-w-0">
              <legend class="text-sm font-semibold text-strong">Riders can pay with</legend>
              <div class="grid">
                <.fare_checkbox
                  :for={medium <- @workspace.media}
                  id={"fare-media-#{medium.fare_media_id}"}
                  name="fare[media_ids][]"
                  value={medium.fare_media_id}
                  checked={medium.fare_media_id in @draft.media_ids}
                  label={medium.name}
                  help={media_type_help(medium)}
                />
              </div>
              <p
                :if={@draft.media_error}
                id="fare-media-error"
                class="mt-2 flex items-start gap-1.5 text-[13px] font-semibold text-error-fg"
              >
                <.icon name="hero-exclamation-circle" class="mt-px size-4 shrink-0" />
                <span>{@draft.media_error}</span>
              </p>
            </fieldset>

            <.fare_result_card draft={@draft} workspace={@workspace} />

            <fieldset :if={@draft.kind == "pass"} id="fare-groups" class="min-w-0">
              <legend class="text-sm font-semibold text-strong">Accepted on</legend>
              <p class="mt-0.5 text-[13px] text-muted">
                A pass covers every ride on the route groups you choose.
              </p>
              <div class="mt-1 grid">
                <.fare_checkbox
                  :for={group <- @workspace.groups}
                  id={"fare-group-#{group.network_id}"}
                  name="fare[group_ids][]"
                  value={group.network_id}
                  checked={group.network_id in @draft.group_ids}
                  label={group.name}
                  help={counted(length(group.route_ids), "route", "routes")}
                />
              </div>
            </fieldset>

            <div :if={@draft.kind != "pass"} id="fare-where">
              <p class="text-sm font-semibold text-strong">Where it’s charged</p>
              <ul :if={@draft.rules != []} class="mt-1 grid gap-1 text-sm">
                <li :for={rule <- @draft.rules}>{fare_rule_sentence(rule, @workspace)}</li>
              </ul>
              <p :if={@draft.rules == []} class="mt-1 text-sm text-muted">
                No fare rule charges this fare yet. After you create it, choose where it applies.
              </p>
              <.button
                id="fare-drawer-where"
                type="button"
                variant="quiet"
                class="-ml-2 min-h-11 px-2"
                phx-click="go_fares_where"
              >
                Change where fares apply
              </.button>
            </div>

            <details id="fare-id-disclosure" class="group">
              <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 text-sm font-semibold text-strong [&::-webkit-details-marker]:hidden">
                <.icon
                  name="hero-chevron-right"
                  class="size-4 text-muted transition-transform group-open:rotate-90 motion-reduce:transition-none"
                /> Fare ID:
                <span class="font-mono text-[13px] font-normal font-normal">
                  {fare_id_text(@draft)}
                </span>
              </summary>
              <p class="pb-2 pl-6 text-[13px] text-muted">
                Used in the exported feed. Filled in from the name until you edit it.
              </p>
            </details>
          </.drawer_scroll>

          <.drawer_footer>
            <.button
              :if={@editing?}
              id="fare-delete"
              type="button"
              variant="quiet"
              class="mr-auto min-h-11 px-2 text-error-fg hover:bg-error-bg"
              phx-click="open_delete_fare"
            >
              <.icon name="hero-trash" class="size-4" /> Delete fare…
            </.button>
            <.button
              id="fare-cancel"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="close_fare_drawer"
            >
              Cancel
            </.button>
            <.button
              id="fare-save"
              type="submit"
              class="min-h-11"
              disabled={@pending?}
              phx-disable-with="Saving…"
            >
              {if @editing?, do: "Save changes", else: "Create fare"}
            </.button>
          </.drawer_footer>
        </.form>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders one price field of the fare drawer: a currency-marked text input that
  keeps exactly what was typed, so an unreadable price shows the typo rather than
  a formatted value that hides it.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, default: "Not sold"
  attr :label, :string, required: true
  attr :invalid?, :boolean, default: false

  def fare_price_input(assigns) do
    ~H"""
    <div class="relative">
      <span class="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-muted">
        $
      </span>
      <input
        type="text"
        id={@id}
        name={@name}
        value={@value}
        inputmode="decimal"
        autocomplete="off"
        placeholder={@placeholder}
        aria-label={@label}
        aria-invalid={to_string(@invalid?)}
        class={[
          "h-11 w-full rounded-control border bg-white pl-7 pr-3 text-right text-sm tabular-nums text-strong",
          "focus-visible:outline-2 focus-visible:outline-offset-[-1px] focus-visible:outline-focus",
          if(@invalid?, do: "border-error-line", else: "border-control")
        ]}
      />
    </div>
    """
  end

  @doc """
  Renders one checkbox of the fare, rider type or payment method drawer: the
  control, its label, and the one line that says what it is for.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :checked, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :help, :string, default: nil

  def fare_checkbox(assigns) do
    ~H"""
    <label
      for={@id}
      class={[
        "flex min-h-11 items-start gap-3 py-2",
        if(@disabled, do: "cursor-not-allowed opacity-60", else: "cursor-pointer")
      ]}
    >
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value={@value}
        checked={@checked}
        disabled={@disabled}
        class="mt-0.5 size-5 shrink-0 accent-action"
      />
      <span class="min-w-0">
        <span class="block text-sm font-semibold text-strong">{@label}</span>
        <span :if={@help} class="block text-[13px] text-muted">{@help}</span>
      </span>
    </label>
    """
  end

  @doc """
  Renders the fare drawer's live result card: what a trip planner will show for
  the prices typed so far, and what the older format keeps of them.
  """
  attr :draft, :map, required: true
  attr :workspace, :map, required: true

  def fare_result_card(assigns) do
    assigns =
      assigns
      |> assign(:default_rider, rider_default(assigns.workspace))
      |> assign(:adult, result_amount(assigns.draft, assigns.draft.amounts, assigns.workspace))
      |> assign(:others, result_others(assigns.draft, assigns.workspace))

    ~H"""
    <div
      id="fare-result-card"
      aria-live="polite"
      class="rounded-card border border-subtle bg-canvas px-4 py-3"
    >
      <p class="text-[13px] text-muted">What trip planners show</p>
      <p class="mt-0.5 font-display text-[26px] font-semibold leading-tight tracking-[-0.02em] tabular-nums text-strong">
        {@adult || "Add a price"}
      </p>
      <p class="mt-1 text-sm text-default">
        {if @others == [],
          do: "Add prices for other rider types above.",
          else: Enum.join(@others, " · ")}
      </p>
      <p class="mt-2 text-sm font-bold text-strong">{older_format_line(@draft, @workspace)}</p>
    </div>
    """
  end

  @doc """
  Renders the confirm dialog that deletes a fare.

  `fare_delete` is the LiveView's whole dialog state: the fare it was opened on,
  the rules that charge it, the replacement select's value, and the error a
  refused confirm produced. Replacement is chosen by fare name, because an
  operator thinks about the fare they are deleting rather than about which of its
  `fare_products` rows a rule happens to name.
  """
  attr :fare_delete, :map, required: true
  attr :workspace, :map, required: true
  attr :return_focus_id, :string, default: nil

  def fare_delete_dialog(assigns) do
    assigns =
      assigns
      |> assign(:fare, assigns.fare_delete.fare)
      |> assign(:rules, assigns.fare_delete.rules)

    ~H"""
    <.confirm_dialog
      id="fare-delete-dialog"
      chrome="planner"
      open={true}
      title={"Delete #{@fare.name}?"}
      confirm_label="Delete fare"
      pending_label="Deleting…"
      on_confirm="delete_fare"
      on_cancel="cancel_delete_fare"
      cancel_label="Keep fare"
      return_focus_id={@return_focus_id}
    >
      <div class="grid gap-4">
        <%= if @rules == [] do %>
          <p id="fare-delete-unused" class="text-sm">
            No fare rule charges {@fare.name}. Its {counted(length(@fare.cells), "price", "prices")} are deleted with it.
          </p>
        <% else %>
          <p id="fare-delete-rules" class="text-sm">
            {counted(length(@rules), "fare rule charges", "fare rules charge")} {@fare.name}:
          </p>
          <ul class="grid gap-1 rounded-card bg-canvas px-3 py-2 text-sm">
            <li :for={rule <- @rules}>{fare_rule_sentence(rule, @workspace)}</li>
          </ul>

          <form id="fare-delete-replacement-form" phx-change="change_fare_replacement">
            <.input
              id="fare-delete-replacement"
              name="replacement"
              type="select"
              label="What should these rides charge instead?"
              value={@fare_delete.replacement || ""}
              options={fare_replacement_options(@fare_delete.fare, @workspace)}
              prompt="Choose a fare"
              errors={List.wrap(@fare_delete.error)}
              help="Removing the rules leaves those rides with no price in trip planners."
            />
          </form>

          <p id="fare-delete-prices" class="text-sm">
            Its {counted(length(@fare.cells), "price", "prices")} are deleted too.
          </p>
        <% end %>

        <p id="fare-delete-undo" class="text-[13px] text-muted">
          Undo is available right after you delete.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  @doc """
  Renders the rider type drawer: its name, the page that says who qualifies for
  it, whether it is the one shown first, and — on a create — the starting prices
  it gets on every fare the version holds.
  """
  attr :draft, :map, required: true
  attr :form, :any, required: true
  attr :workspace, :map, required: true
  attr :version_name, :string, default: nil
  attr :return_focus_id, :string, default: nil
  attr :pending?, :boolean, default: false

  def rider_drawer(assigns) do
    assigns =
      assigns
      |> assign(:editing?, assigns.draft.key != nil)
      |> assign(:title, rider_drawer_title(assigns.draft))
      |> assign(:default_rider, rider_default(assigns.workspace))

    ~H"""
    <.drawer
      id="rider-drawer"
      chrome="planner"
      open={true}
      pending={@pending?}
      on_close="close_rider_drawer"
      title={@title}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
      class="max-w-[480px]"
    >
      <:lede>
        Changes apply to {version_phrase(@version_name, true)} as soon as you save.
      </:lede>

      <div
        id="rider-drawer-content"
        phx-hook="FormErrorFocus"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.form
          for={@form}
          id="rider-form"
          as={:rider}
          novalidate
          phx-change="validate_rider"
          phx-submit="save_rider_type"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.form_error_summary
              id="error-summary"
              title={fare_error_summary_title(length(@draft.failures))}
              failures={@draft.failures}
            />

            <.input
              id="rider-name"
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="For example, Reduced fare"
              errors={List.wrap(@draft.name_error)}
              help="As riders see it, such as “Reduced fare” or “Youth (6–18)”."
              autocomplete="off"
              phx-debounce="300"
            />

            <.input
              id="rider-url"
              field={@form[:eligibility_url]}
              type="url"
              label="Web page about who qualifies"
              placeholder="https://"
              help="Trip planners link to it. Say there who qualifies and what proof they need."
              autocomplete="off"
              phx-debounce="300"
            />

            <.fare_checkbox
              id="rider-default"
              name="rider[default?]"
              value="true"
              checked={@draft.default?}
              disabled={@draft.default_locked?}
              label="Show these prices first in trip planners"
              help={
                if @draft.default_locked?,
                  do:
                    "This is the one shown first. To change that, open another rider type and choose it instead.",
                  else: "Usually Adult. Only one rider type can be shown first."
              }
            />

            <div :if={not @editing?}>
              <.choice_cards
                id="rider-starting"
                name="rider[starting]"
                type="radio"
                label="Starting prices"
                help="You can change each price on the Prices tab afterwards."
                selected={List.wrap(@draft.starting)}
                options={[
                  %{
                    value: "half",
                    label: "Half the adult price",
                    description: "Rounded to the nearest 5 cents."
                  },
                  %{
                    value: "same",
                    label: "Same as adult",
                    description: "Useful when only some fares differ."
                  },
                  %{
                    value: "free",
                    label: "Free",
                    description: "Every fare costs nothing for this rider type."
                  },
                  %{
                    value: "blank",
                    label: "Leave blank",
                    description: "Not sold until you enter prices."
                  }
                ]}
              />

              <div
                id="rider-starting-preview"
                aria-live="polite"
                class="rounded-card border border-subtle bg-canvas px-4 py-3"
              >
                <p class="text-[13px] text-muted">Prices this creates</p>
                <p
                  :for={fare <- Enum.take(@workspace.fares, 1)}
                  class="mt-0.5 text-sm font-bold text-strong"
                >
                  {rider_starting_text(@draft, fare, @default_rider)} {fare.name}
                </p>
                <p :if={@workspace.fares == []} class="mt-0.5 text-sm font-bold text-strong">
                  Not sold yet
                </p>
                <p class="mt-2 text-sm font-bold text-strong">
                  Adds a column to the fare table and {counted(
                    starting_price_count(@draft, @workspace.fares),
                    "price",
                    "prices"
                  )} to the newer format.
                </p>
              </div>
            </div>
          </.drawer_scroll>

          <.drawer_footer>
            <.button
              :if={@editing? and not @draft.default?}
              id="rider-delete"
              type="button"
              variant="quiet"
              class="mr-auto min-h-11 px-2 text-error-fg hover:bg-error-bg"
              phx-click="open_delete_rider"
            >
              <.icon name="hero-trash" class="size-4" /> Delete rider type…
            </.button>
            <.button
              id="rider-cancel"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="close_rider_drawer"
            >
              Cancel
            </.button>
            <.button
              id="rider-save"
              type="submit"
              class="min-h-11"
              disabled={@pending?}
              phx-disable-with="Saving…"
            >
              {if @editing?, do: "Save changes", else: "Create rider type"}
            </.button>
          </.drawer_footer>
        </.form>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders the confirm dialog that deletes a rider type: the prices it removes and
  the trip-planner answer they leave behind.
  """
  attr :rider_delete, :map, required: true
  attr :workspace, :map, required: true
  attr :return_focus_id, :string, default: nil

  def rider_delete_dialog(assigns) do
    assigns = assign(assigns, :default_rider, rider_default(assigns.workspace))

    ~H"""
    <.confirm_dialog
      id="rider-delete-dialog"
      chrome="planner"
      open={true}
      title={"Delete #{@rider_delete.name}?"}
      confirm_label="Delete rider type"
      pending_label="Deleting…"
      on_confirm="delete_rider_type"
      on_cancel="cancel_delete_rider"
      cancel_label="Keep rider type"
      return_focus_id={@return_focus_id}
    >
      <div class="grid gap-3">
        <p id="rider-delete-prices" class="text-sm">
          This deletes the {@rider_delete.name} column and its {counted(
            @rider_delete.price_count,
            "price",
            "prices"
          )}.
          Trip planners will show these riders the {@default_rider.name} prices.
        </p>
        <p id="rider-delete-older" class="text-sm">
          The older format isn’t affected: it has only adult prices.
        </p>
        <p id="rider-delete-undo" class="text-[13px] text-muted">
          Undo is available right after you delete.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  @doc """
  Renders the payment method drawer: its name, which of GTFS's five kinds it is,
  and the fares that accept it.
  """
  attr :draft, :map, required: true
  attr :form, :any, required: true
  attr :workspace, :map, required: true
  attr :return_focus_id, :string, default: nil
  attr :pending?, :boolean, default: false

  def media_drawer(assigns) do
    assigns =
      assigns
      |> assign(:editing?, assigns.draft.key != nil)
      |> assign(:title, media_drawer_title(assigns.draft))

    ~H"""
    <.drawer
      id="media-drawer"
      chrome="planner"
      open={true}
      pending={@pending?}
      on_close="close_media_drawer"
      title={@title}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
      class="max-w-[520px]"
    >
      <:lede>
        Payment methods appear only in the newer format. The older format records only whether
        riders pay on board or before boarding.
      </:lede>

      <div
        id="media-drawer-content"
        phx-hook="FormErrorFocus"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.form
          for={@form}
          id="media-form"
          as={:media}
          novalidate
          phx-change="validate_media"
          phx-submit="save_payment_method"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.form_error_summary
              id="error-summary"
              title={fare_error_summary_title(length(@draft.failures))}
              failures={@draft.failures}
            />

            <.input
              id="media-name"
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="For example, NCT Ride app"
              errors={List.wrap(@draft.name_error)}
              help="Use the name riders know, such as the card or app brand. For cash, “Cash on board” is enough."
              autocomplete="off"
              phx-debounce="300"
            />

            <.choice_cards
              id="media-kind"
              name="media[fare_media_type]"
              type="radio"
              label="Kind"
              selected={[to_string(@draft.fare_media_type)]}
              options={media_type_options()}
            />

            <fieldset class="min-w-0">
              <legend class="text-sm font-semibold text-strong">Accepted for</legend>
              <p class="mt-0.5 text-[13px] text-muted">
                To charge a different price with this method, open the fare and choose “Price differs
                by payment method”.
              </p>
              <div class="mt-1 grid sm:grid-cols-2">
                <.fare_checkbox
                  :for={fare <- @workspace.fares}
                  id={"media-fare-#{fare_slug(fare)}"}
                  name="media[accepted_products][]"
                  value={List.first(fare.product_ids)}
                  checked={List.first(fare.product_ids) in @draft.accepted_products}
                  label={fare.name}
                />
              </div>
            </fieldset>
          </.drawer_scroll>

          <.drawer_footer>
            <.button
              :if={@editing?}
              id="media-delete"
              type="button"
              variant="quiet"
              class="mr-auto min-h-11 px-2 text-error-fg hover:bg-error-bg"
              phx-click="open_delete_media"
            >
              <.icon name="hero-trash" class="size-4" /> Delete payment method…
            </.button>
            <.button
              id="media-cancel"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="close_media_drawer"
            >
              Cancel
            </.button>
            <.button
              id="media-save"
              type="submit"
              class="min-h-11"
              disabled={@pending?}
              phx-disable-with="Saving…"
            >
              {if @editing?, do: "Save changes", else: "Create payment method"}
            </.button>
          </.drawer_footer>
        </.form>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders the confirm dialog that deletes a payment method and the prices that
  named it.
  """
  attr :media_delete, :map, required: true
  attr :return_focus_id, :string, default: nil

  def media_delete_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="media-delete-dialog"
      chrome="planner"
      open={true}
      title={"Delete #{@media_delete.name}?"}
      confirm_label="Delete payment method"
      pending_label="Deleting…"
      on_confirm="delete_payment_method"
      on_cancel="cancel_delete_media"
      cancel_label="Keep payment method"
      return_focus_id={@return_focus_id}
    >
      <div class="grid gap-3">
        <p id="media-delete-prices" class="text-sm">
          This deletes every price riders bought with the {@media_delete.name}, across {counted(
            @media_delete.fare_count,
            "fare",
            "fares"
          )}. Riders pay on board unless another
          payment method is chosen.
        </p>
        <p id="media-delete-undo" class="text-[13px] text-muted">
          Undo is available right after you delete.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  # -- Setup, fare-free and conversion ------------------------------------------

  @doc """
  Renders the first-use setup: the four questions a version with no fare rows at
  all asks before it can price a ride.

  `setup` is the LiveView's own draft, rebuilt from the form on every change:
  the structure, the adult price or the route groups' own, the rider types the
  agency charges less for, the transfer answer and its minutes, plus whatever the
  last submit found. `form` is the `to_form` of the same draft, so the price and
  minutes fields render through `<.input>` while the choice cards and the
  checkboxes are named plainly.

  The live result card under the questions recomputes from the draft as it is
  typed, so the answer is what riders will see rather than a promise about it.
  Nothing here writes: "Create fares" is the form's own submit, and the writer
  it reaches is `GtfsPlanner.Gtfs.Fares.Conversion.setup/2`.
  """
  attr :setup, :map, required: true
  attr :form, :any, required: true
  attr :version_name, :string, required: true
  attr :published?, :boolean, default: true

  def fare_setup(assigns) do
    assigns = assign(assigns, :priced?, assigns.setup["kind"] != "free")

    ~H"""
    <section id="fare-setup" class="rounded-card border border-subtle bg-white px-4 py-5 sm:px-6">
      <h2 class="font-display text-[26px] font-semibold tracking-[-0.02em] text-strong">
        Set up fares for {setup_version_phrase(@version_name)}
      </h2>
      <p class="mt-1 max-w-[70ch] text-sm text-muted">
        This version has no fares yet, so trip planners show no price for any ride. Answer the
        questions below to create a starting set. You can change every price and rule afterwards.
      </p>

      <.form
        for={@form}
        id="fare-setup-form"
        as={:setup}
        novalidate
        phx-change="validate_setup"
        phx-submit="create_fares"
        class="mt-6 grid max-w-[760px] gap-7"
      >
        <.form_error_summary
          id="setup-error-summary"
          title={setup_error_title(length(@setup["failures"]))}
          failures={@setup["failures"]}
          class="mb-0"
        />

        <section class="grid gap-3">
          <.step_head id="setup-step-1" number={1} title="How do riders pay for a ride?" />
          <div class="pl-0 sm:pl-10">
            <.choice_cards
              id="setup-kind"
              name="setup[kind]"
              type="radio"
              label="Pricing structure"
              selected={List.wrap(@setup["kind"])}
              options={setup_structure_options()}
            />
          </div>
        </section>

        <section :if={@priced?} class="grid gap-3">
          <.step_head
            id="setup-step-2"
            number={2}
            title={setup_price_question(@setup["kind"])}
          />
          <div class="pl-0 sm:pl-10">
            <div :if={@setup["kind"] != "route"} class="grid gap-2">
              <div class="max-w-[220px]">
                <label for="setup-adult" class="mb-1 block text-base font-semibold">
                  {setup_price_label(@setup["kind"])}
                </label>
                <.fare_price_input
                  id="setup-adult"
                  name="setup[adult]"
                  value={@setup["adult"]}
                  label={setup_price_label(@setup["kind"])}
                  invalid?={@setup["adult_error"] != nil}
                />
                <p
                  :if={@setup["adult_error"]}
                  id="setup-adult-error"
                  class="mt-1 flex items-start gap-1.5 text-[13px] font-semibold text-error-fg"
                >
                  <.icon name="hero-exclamation-circle" class="mt-px size-4 shrink-0" />
                  <span>{@setup["adult_error"]}</span>
                </p>
                <p :if={setup_price_help(@setup["kind"])} class="mt-1.5 text-sm text-muted">
                  {setup_price_help(@setup["kind"])}
                </p>
              </div>
              <p :if={@setup["kind"] == "zone"} id="setup-zone-help" class="text-sm text-default">
                You’ll draw zones and set a price for each pair of zones next.
              </p>
            </div>

            <fieldset :if={@setup["kind"] == "route"} id="setup-groups" class="min-w-0">
              <legend class="sr-only">Route groups and their adult prices</legend>
              <div class="grid gap-3">
                <div
                  :for={group <- Enum.with_index(@setup["groups"])}
                  class="grid grid-cols-1 gap-3 sm:grid-cols-[minmax(0,1fr)_140px]"
                >
                  <.input
                    id={"setup-group-#{elem(group, 1)}-name"}
                    name={"setup[groups][#{elem(group, 1)}][name]"}
                    type="text"
                    label="Route group"
                    value={elem(group, 0)["name"]}
                    placeholder="Local routes"
                    autocomplete="off"
                    class="min-h-11"
                  />
                  <.fare_price_input
                    id={"setup-group-#{elem(group, 1)}-price"}
                    name={"setup[groups][#{elem(group, 1)}][price]"}
                    value={elem(group, 0)["price"]}
                    label={"#{elem(group, 0)["name"] || "Route group"} adult price"}
                  />
                </div>
              </div>
              <.button
                id="add-route-group"
                type="button"
                variant="quiet"
                class="mt-3 min-h-11"
                phx-click="add_route_group"
              >
                <.icon name="hero-plus" class="size-4" /> Add route group
              </.button>
              <p class="mt-2 text-[13px] text-muted">
                You choose which routes belong to each group on Where fares apply. Routes start in
                the first group.
              </p>
            </fieldset>
          </div>
        </section>

        <section :if={@priced?} class="grid gap-3">
          <.step_head id="setup-step-3" number={3} title="Do some riders pay less?">
            Each becomes a rider type with its own column of prices.
          </.step_head>
          <div class="grid pl-0 sm:pl-10">
            <.fare_checkbox
              id="setup-reduced"
              name="setup[reduced]"
              value="true"
              checked={@setup["reduced"]}
              label="Reduced fare for seniors and riders with disabilities, at half price"
              help="US transit agencies that receive FTA formula funds must offer these riders no more than half the peak fare during off-peak hours."
            />
            <.fare_checkbox
              id="setup-youth"
              name="setup[youth]"
              value="true"
              checked={@setup["youth"]}
              label="Youth fare"
              help="Starts at half price. Set the age range on the rider type’s eligibility page."
            />
            <.fare_checkbox
              id="setup-child"
              name="setup[child]"
              value="true"
              checked={@setup["child"]}
              label="Young children ride free"
              help="Creates “Children under 6” with free fares. Rename it to match your policy."
            />
          </div>
        </section>

        <section :if={@priced?} class="grid gap-3">
          <.step_head
            id="setup-step-4"
            number={4}
            title="Can riders change buses without paying again?"
          />
          <div class="grid pl-0 sm:pl-10">
            <.fare_checkbox
              id="setup-transfer"
              name="setup[transfer]"
              value="true"
              checked={@setup["transfer"]}
              label={transfer_label(@setup["minutes"])}
              help="Change the time limit and the number of changes on the Transfers tab."
            />
            <div :if={@setup["transfer"]} class="mt-2 max-w-[200px]">
              <.input
                id="setup-minutes"
                field={@form[:minutes]}
                type="number"
                label="Free transfers within (minutes)"
                value={@setup["minutes"]}
                min="1"
                errors={List.wrap(@setup["minutes_error"])}
                phx-debounce="300"
              />
            </div>
          </div>
        </section>

        <div class="grid gap-3 pl-0 sm:pl-10">
          <.setup_result setup={@setup} currency={setup_currency(@setup)} />
          <div class="flex flex-wrap items-center gap-3">
            <.button id="setup-create" type="submit" class="min-h-11">
              Create fares
            </.button>
          </div>
        </div>
      </.form>
    </section>
    """
  end

  @doc """
  Renders the fare-free summary: the one state where the version holds a fare and
  the answer is that every ride costs nothing.

  The summary replaces the grid rather than sitting above it, because the grid's
  whole vocabulary is a price an operator can change and there is none here.
  "Start charging fares" opens the same fare drawer the grid's own names open, so
  the next step is editing the fare the setup created rather than answering the
  setup questions a second time — `Conversion.setup/2` refuses a version that
  already holds fare rows.
  """
  attr :workspace, :map, required: true
  attr :version_name, :string, required: true

  def fare_free_summary(assigns) do
    ~H"""
    <section id="fare-free" class="rounded-card border border-subtle bg-white">
      <div class="flex flex-wrap items-start gap-5 px-4 py-5 sm:px-6">
        <span class="flex size-12 shrink-0 items-center justify-center rounded-control bg-canvas text-strong">
          <.icon name="hero-ticket" class="size-6" />
        </span>
        <div class="min-w-0 flex-1 basis-[360px]">
          <h2 class="font-display text-[26px] font-semibold tracking-[-0.02em] text-strong">
            Riders ride free
          </h2>
          <p id="fare-free-lede" class="mt-1 text-sm text-default">
            Every ride on every route is free for every rider. Trip planners show “Free” for
            journeys on {setup_version_phrase(@version_name)}.
          </p>
          <dl class="mt-4 grid gap-x-8 gap-y-3 sm:grid-cols-2">
            <div>
              <dt class="text-[13px] text-muted">In the exported feed</dt>
              <dd class="text-sm text-strong">
                One free fare for all routes, in both GTFS fare formats
              </dd>
            </div>
            <div>
              <dt class="text-[13px] text-muted">Changed</dt>
              <dd id="fare-free-changed" class="text-sm text-strong">{changed_by(@workspace)}</dd>
            </div>
          </dl>
        </div>
        <.button
          id="start-charging-fares"
          type="button"
          class="min-h-11"
          phx-click="open_fare_drawer"
          phx-value-fare_product_id={free_fare_product_id(@workspace)}
          phx-value-opener_id="start-charging-fares"
        >
          Start charging fares
        </.button>
      </div>
    </section>
    """
  end

  @doc """
  Renders a version whose fares came from an import and are not editable here.

  The stored fares are shown exactly as they are: the `fare_attributes` rows as
  adult prices when the import used only the older format, and the version's own
  `fare_products` rows through the read-only fare table when it used Fares v2.
  There is no price input anywhere, because every writer of this package refuses
  an unmanaged version.

  "Edit fares" opens the conversion review, which is the only path from an
  imported feed to an editable one.
  """
  attr :workspace, :map, required: true
  attr :unmanaged, :map, required: true

  def unmanaged_fares(assigns) do
    ~H"""
    <div id="unmanaged-fares" class="grid grid-cols-1 gap-4">
      <.message
        id="imported-fares"
        kind="info"
        title="These fares came from your imported feed, which uses only the older GTFS fare format"
      >
        That format has one adult price per fare and no fare names, so each fare is named after
        its feed ID. Rename them, and add rider types, passes or payment methods if riders have
        them. Exports now also include the newer format, built from this table.
        <:action>
          <.button
            id="edit-fares"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="open_conversion_review"
            phx-value-opener_id="edit-fares"
          >
            <.icon name="hero-pencil-square" class="size-4" /> Edit fares
          </.button>
        </:action>
      </.message>

      <.fare_table
        :if={@unmanaged.format == :v2}
        workspace={@workspace}
        edits={%{}}
        readonly?
      />

      <section
        :if={@unmanaged.format == :v1}
        id="unmanaged-v1-table"
        class="overflow-clip rounded-card border border-subtle bg-white"
      >
        <div class="border-b border-subtle px-4 py-2.5 sm:px-5">
          <h2 class="font-sans text-base font-bold tracking-normal text-strong">Fares as imported</h2>
          <p class="text-[13px] text-muted">
            {counted(length(@unmanaged.attributes), "fare", "fares")} · one adult price per fare ·
            prices in {currency_name(@workspace.currency)}
          </p>
        </div>
        <div class="overflow-x-auto">
          <table class="w-full border-collapse text-sm">
            <caption class="sr-only">
              Each imported fare, its adult price and the free transfers it allows.
            </caption>
            <thead>
              <tr>
                <th
                  scope="col"
                  class="min-w-[240px] border-b border-subtle bg-canvas px-4 py-2 text-left text-[13px] font-semibold text-strong"
                >
                  Fare
                </th>
                <th
                  scope="col"
                  class="w-[140px] border-b border-subtle bg-canvas px-4 py-2 text-right text-[13px] font-semibold text-strong"
                >
                  Adult price
                </th>
                <th
                  scope="col"
                  class="border-b border-subtle bg-canvas px-4 py-2 text-left text-[13px] font-semibold text-strong"
                >
                  Free transfers
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={attribute <- @unmanaged.attributes} class="hover:bg-canvas/60">
                <th
                  scope="row"
                  class="border-b border-subtle px-4 py-2 text-left align-top font-normal"
                >
                  <span class="block text-sm font-bold text-strong">{attribute.fare_id}</span>
                  <span class="block text-[12px] text-muted">
                    Named after its feed ID. Riders see this name.
                  </span>
                </th>
                <td class="border-b border-subtle px-4 py-2 text-right align-top tabular-nums text-strong">
                  {attribute.price |> Money.format(@workspace.currency)}
                </td>
                <td class="border-b border-subtle px-4 py-2 align-top text-default">
                  {transfer_allowance(attribute)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end

  @doc """
  Renders the conversion review: what converting this version's imported fares
  would write, or why it must not.

  `conversion` is the LiveView's whole review state. `:state` is `:ok` with the
  plan `GtfsPlanner.Gtfs.Fares.Conversion.preview/2` returned — the rows each
  table would gain, the differences R12 records rather than refuses, and the
  `contains_id` rules that stay in the older format — or `:refused` with the
  reasons it answered instead.

  A refused review offers Close alone: there is no Convert button to press over
  a conversion R12 forbids, so nothing here can be mistaken for one.
  """
  attr :conversion, :map, required: true
  attr :return_focus_id, :string, default: nil

  def conversion_review(assigns) do
    ~H"""
    <.confirm_dialog
      id="conversion-review"
      chrome="planner"
      open={true}
      size="xl"
      title={conversion_title(@conversion)}
      confirm_label="Convert fares"
      pending_label="Converting…"
      on_confirm="convert_fares"
      on_cancel="close_conversion_review"
      cancel_label="Close"
      return_focus_id={@return_focus_id}
      single_action={@conversion.state == :refused}
    >
      <div id="conversion-review-content" class="grid gap-4">
        <%= if @conversion.state == :refused do %>
          <div id="conversion-review-refused" class="grid gap-3">
            <p class="text-sm font-semibold text-error-fg">
              These fares can’t be edited here yet, and nothing was written.
            </p>
            <ul class="grid gap-2 text-sm">
              <li
                :for={reason <- @conversion.reasons}
                id={"conversion-refusal-#{reason.code}"}
                class="rounded-card bg-canvas px-3 py-2"
              >
                <span class="block font-bold text-strong">{reason.message}</span>
                <ul :if={reason.examples != []} class="mt-1 list-disc pl-5 text-default">
                  <li :for={example <- reason.examples}>{example}</li>
                </ul>
              </li>
            </ul>
          </div>
        <% else %>
          <p id="conversion-review-summary" class="text-sm text-default">
            Converting builds the newer GTFS fare files from these rows.
          </p>

          <p id="conversion-price-differences" class="text-sm text-default">
            <span class="font-bold text-strong">
              {@conversion.plan.price_differences}
            </span>
            price differences: no rider is charged a different price, because the conversion is
            checked against every combination this version can be asked for and a difference
            refuses the whole conversion.
          </p>

          <div>
            <h4 class="text-[13px] font-bold text-strong">What it creates</h4>
            <ul id="conversion-counts" class="mt-1 grid gap-0.5 text-sm text-default">
              <li :for={row <- conversion_counts(@conversion.plan)}>{row}</li>
            </ul>
          </div>

          <div :if={@conversion.plan.known_differences != []}>
            <h4 class="text-[13px] font-bold text-strong">What changes for riders</h4>
            <ul id="conversion-known-differences" class="mt-1 list-disc pl-5 text-sm text-default">
              <li :for={difference <- @conversion.plan.known_differences}>{difference}</li>
            </ul>
          </div>

          <div :if={@conversion.plan.kept_older_only != []}>
            <h4 class="text-[13px] font-bold text-strong">Kept in the older format</h4>
            <ul
              id="conversion-kept-older"
              class="mt-1 grid gap-1 text-sm text-default"
            >
              <li :for={row <- @conversion.plan.kept_older_only}>
                <span class="font-semibold text-strong">{row.fare_id}</span>
                {row.reason}
              </li>
            </ul>
          </div>

          <p id="conversion-review-note" class="text-[13px] text-muted">
            Your imported files are left exactly as they were. Undo reverses the conversion and
            returns the version to what was imported.
          </p>
        <% end %>

        <p
          :if={@conversion.error}
          id="conversion-review-error"
          class="text-sm font-semibold text-error-fg"
        >
          {@conversion.error}
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  @doc """
  Renders the Where tab's lede and its route groups table: one row per group
  with its route badges and how a ride on it is charged, plus the "In no group"
  warning row for the version's routes no group holds.

  Everything here is read from the workspace's own `groups` and `routes`, so the
  table, the matrices below it and the passes table cannot disagree about which
  routes a group holds. The group name is a button that opens that group's
  drawer; "Create route group" is the card's own secondary action, because the
  tab's one primary is Add fare rule in the header.
  """
  attr :workspace, :map, required: true

  def route_groups_card(assigns) do
    ~H"""
    <section
      id="route-groups-card"
      aria-labelledby="route-groups-title"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-start gap-x-6 gap-y-2 border-b border-subtle px-4 py-3 sm:px-5">
        <div class="min-w-0 flex-1 basis-[420px]">
          <h2
            id="route-groups-title"
            class="font-sans text-base font-bold tracking-normal text-strong"
          >
            Route groups
          </h2>
          <p class="mt-0.5 text-[13px] text-muted">
            Routes that charge the same fares, such as local and intercity routes. Each route is
            in one group.
          </p>
        </div>
        <.button
          id="create-route-group"
          variant="secondary"
          class="min-h-11"
          phx-click="open_group_drawer"
        >
          <.icon name="hero-plus" class="size-4" /> Create route group
        </.button>
      </div>

      <div class="overflow-x-auto">
        <table id="route-groups" class="w-full border-collapse text-sm">
          <caption class="sr-only">
            The version's route groups, the routes in each, and the fare a ride on them pays.
          </caption>
          <thead>
            <tr class="text-left">
              <th
                scope="col"
                class="w-[220px] border-b border-subtle bg-canvas px-4 py-2 text-[13px] font-semibold text-strong"
              >
                Group
              </th>
              <th
                scope="col"
                class="border-b border-subtle bg-canvas px-4 py-2 text-[13px] font-semibold text-strong"
              >
                Routes
              </th>
              <th
                scope="col"
                class="w-[300px] border-b border-subtle bg-canvas px-4 py-2 text-[13px] font-semibold text-strong"
              >
                Which fare a ride pays
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={group <- @workspace.groups}
              id={"route-group-#{group.network_id}"}
              class="hover:bg-canvas/60"
            >
              <th
                scope="row"
                class="border-b border-subtle px-4 py-2.5 text-left align-top font-normal"
              >
                <button
                  type="button"
                  id={"edit-group-#{group.network_id}"}
                  phx-click="open_group_drawer"
                  phx-value-network_id={group.network_id}
                  class="group/name block min-h-11 w-full text-left"
                >
                  <span class="block text-sm font-bold text-strong underline decoration-subtle underline-offset-4 group-hover/name:decoration-action">
                    {group.name || group.network_id}
                  </span>
                  <span class="block text-[13px] font-normal text-muted">
                    {route_count_text(length(group.route_ids))}
                  </span>
                </button>
              </th>
              <td class="border-b border-subtle px-4 py-2.5 align-top">
                <div class="flex max-w-[520px] flex-wrap gap-1">
                  <.route_badges
                    :for={route <- group_route_badges(group, @workspace)}
                    route={route}
                  />
                </div>
              </td>
              <td class="border-b border-subtle px-4 py-2.5 align-top text-sm">
                <%= cond do %>
                  <% group.zone_priced? -> %>
                    <span id={"group-charge-#{group.network_id}"}>
                      By zone ·
                      <a
                        href={"#zone-matrix-#{group.network_id}"}
                        class="font-semibold text-strong underline decoration-subtle underline-offset-4 hover:decoration-action"
                      >
                        see the zone table
                      </a>
                    </span>
                  <% flat = flat_rule_fare(group, @workspace) -> %>
                    <span id={"group-charge-#{group.network_id}"}>
                      {flat.name}{if amount = adult_amount_text(flat, @workspace),
                        do: " · #{amount} adult"},
                      any stops
                    </span>
                  <% true -> %>
                    <span
                      id={"group-charge-#{group.network_id}"}
                      class="font-semibold text-warning-fg"
                    >
                      No fare yet
                    </span>
                <% end %>
              </td>
            </tr>

            <tr
              :if={loose_routes(@workspace) != []}
              id="route-groups-unassigned"
              class="bg-warning-bg"
            >
              <th
                scope="row"
                class="border-b border-subtle bg-warning-bg px-4 py-2.5 text-left align-top text-sm font-bold text-warning-fg"
              >
                <span class="flex items-center gap-2">
                  <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" /> In no group
                </span>
              </th>
              <td class="border-b border-subtle bg-warning-bg px-4 py-2.5">
                <div class="flex flex-wrap gap-1">
                  <.route_badges :for={route <- loose_routes(@workspace)} route={route} />
                </div>
              </td>
              <td class="border-b border-subtle bg-warning-bg px-4 py-2.5 text-sm text-warning-fg">
                No fare. Trip planners show no price.
                <.button
                  id="add-unassigned-to-group"
                  variant="quiet"
                  class="min-h-11 !text-warning-fg underline"
                  phx-click="open_group_drawer"
                  phx-value-network_id={first_group_id(@workspace)}
                >
                  Add to a group
                </.button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  @doc """
  Renders one zone fare matrix: rows are where a ride starts and columns where
  it ends, every cell a button that opens the cell dialog for that pair.

  `matrix` is the workspace's own entry for a zone-priced group, so a cell's
  "No fare" flag is the read model's rather than a guess: a pair nobody priced
  is present and flagged, and that is what the cell dialog writes through. A
  warning cell carries an icon and the words, never colour alone.
  """
  attr :matrix, :map, required: true
  attr :workspace, :map, required: true

  def zone_matrix(assigns) do
    ~H"""
    <section
      id={"zone-matrix-#{@matrix.network_id}"}
      aria-labelledby={"zone-matrix-title-#{@matrix.network_id}"}
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle px-4 py-3 sm:px-5">
        <h2
          id={"zone-matrix-title-#{@matrix.network_id}"}
          class="font-sans text-base font-bold tracking-normal text-strong"
        >
          Zone fares on {group_name(@workspace, @matrix.network_id)}
        </h2>
        <p class="mt-0.5 text-[13px] text-muted">
          Rows are where a ride starts, columns where it ends. Adult prices; other rider types
          follow the Prices tab. Select a cell to change its fare.
        </p>
      </div>

      <div class="overflow-x-auto p-4 sm:p-5">
        <table class="w-full min-w-[560px] border-collapse overflow-hidden rounded-card border border-subtle text-sm">
          <caption class="sr-only">
            The fare for a ride in each zone pair on {group_name(@workspace, @matrix.network_id)}.
          </caption>
          <thead>
            <tr>
              <td class="w-[200px] border-b border-subtle bg-canvas px-3 py-2 text-[12px] text-muted">
                From ↓ &nbsp; To →
              </td>
              <th
                :for={zone <- @matrix.zones}
                scope="col"
                class="border-b border-l border-subtle bg-canvas px-3 py-2 text-[13px] font-semibold text-strong"
              >
                {zone.name}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={from <- @matrix.zones}>
              <th
                scope="row"
                class="border-b border-subtle bg-canvas px-3 py-2 text-left text-[13px] font-semibold text-strong"
              >
                {from.name}
              </th>
              <td
                :for={to <- @matrix.zones}
                class="border-b border-l border-subtle p-0"
              >
                <.matrix_cell
                  network_id={@matrix.network_id}
                  from={from}
                  to={to}
                  cell={
                    Map.get(@matrix.cells, {from.area_id, to.area_id}, %{
                      products: [],
                      gap?: true
                    })
                  }
                  workspace={@workspace}
                />
              </td>
            </tr>
          </tbody>
        </table>

        <p class="mt-3 text-[13px] text-muted">
          Riders pay by where they board and where they get off. A ride that only passes through a
          zone isn’t charged for it.
        </p>
      </div>
    </section>
    """
  end

  @doc false
  # One cell of a zone matrix. A pair nobody priced is a warning cell: the words
  # and an icon, not a colour on its own, and a 44 px target like every other
  # control on the tab.
  attr :network_id, :string, required: true
  attr :from, :map, required: true
  attr :to, :map, required: true
  attr :cell, :map, required: true
  attr :workspace, :map, required: true

  defp matrix_cell(assigns) do
    ~H"""
    <button
      type="button"
      id={"cell-#{@network_id}-#{@from.area_id}-#{@to.area_id}"}
      data-cell={cell_key(@from, @to)}
      data-gap={to_string(@cell.gap?)}
      phx-click="open_cell"
      phx-value-network_id={@network_id}
      phx-value-from={@from.area_id}
      phx-value-to={@to.area_id}
      aria-label={cell_aria_label(@cell, @from, @to, @workspace)}
      class={[
        "flex min-h-11 w-full flex-col items-center justify-center gap-0.5 px-2 py-1.5 hover:underline",
        if(@cell.gap?,
          do: "bg-warning-bg font-bold text-warning-fg",
          else: "hover:bg-canvas"
        )
      ]}
    >
      <%= if @cell.gap? do %>
        <span class="flex items-center gap-1.5 text-sm">
          <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" /> No fare
        </span>
        <span class="text-[12px] font-normal">Set fare</span>
      <% else %>
        <span class="text-sm font-semibold tabular-nums text-strong">
          {cell_price_text(@cell, @workspace)}
        </span>
        <span class="text-[12px] text-muted">{cell_fare_names(@cell, @workspace)}</span>
        <.badge :if={length(@cell.products) > 1} tone="warning" class="mt-0.5">
          {length(@cell.products)} fares
        </.badge>
      <% end %>
    </button>
    """
  end

  @doc """
  Renders the dialog that sets one zone matrix cell's fare: the single rides as a
  radio list with their adult prices, "No fare", and — for a pair of different
  zones — the choice to set the reverse cell too.

  The whole dialog is one form whose confirm button submits it, so the fare and
  the "also for the return ride" answer travel with the write rather than being
  pushed as a separate event.
  """
  attr :cell, :map, required: true
  attr :form, :any, required: true
  attr :workspace, :map, required: true
  attr :version_name, :string, required: true
  attr :published?, :boolean, default: true
  attr :return_focus_id, :string, default: nil
  attr :pending?, :boolean, default: false

  def cell_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="cell-dialog"
      chrome="planner"
      size="2xl"
      open={true}
      pending={@pending?}
      title={"Fare from #{@cell.from_name} to #{@cell.to_name}"}
      confirm_label="Save fare"
      pending_label="Saving…"
      confirm_disabled={@cell.error != nil}
      on_confirm="set_zone_fare"
      on_cancel="close_cell"
      cancel_label="Cancel"
      confirm_form="cell-form"
      return_focus_id={@return_focus_id}
    >
      <p id="cell-dialog-context" class="flex flex-wrap items-center gap-2 text-[13px] text-muted">
        <span>{@cell.group_name}</span>
        <span aria-hidden="true">·</span>
        <span>{version_phrase(@version_name, @published?)}</span>
      </p>

      <.form
        for={@form}
        id="cell-form"
        as={:cell}
        novalidate
        phx-change="change_cell"
        phx-submit="set_zone_fare"
        class="mt-4 grid gap-4"
      >
        <input type="hidden" name="cell[from]" value={@cell.from} />
        <input type="hidden" name="cell[to]" value={@cell.to} />
        <input type="hidden" name="cell[both]" value="false" />

        <fieldset id="cell-fares">
          <legend class="text-sm font-semibold text-strong">Fare</legend>
          <div class="mt-2 grid gap-1">
            <label
              :for={fare <- single_fares(@workspace)}
              class="flex min-h-11 cursor-pointer items-center gap-3 rounded-control px-2 has-[:checked]:bg-selection"
            >
              <input
                type="radio"
                id={"cell-fare-#{fare.key}"}
                name="cell[fare_product_id]"
                value={fare.key}
                checked={@cell.fare_product_id == fare.key}
                class="size-4 accent-action"
              />
              <span class="flex-1 text-sm font-semibold text-strong">{fare.name}</span>
              <span class="text-sm tabular-nums text-default">{fare.price}</span>
            </label>

            <label
              for="cell-fare-none"
              class="flex min-h-11 cursor-pointer items-center gap-3 rounded-control px-2 has-[:checked]:bg-selection"
            >
              <input
                type="radio"
                id="cell-fare-none"
                name="cell[fare_product_id]"
                value=""
                checked={is_nil(@cell.fare_product_id)}
                class="size-4 accent-action"
              />
              <span class="flex-1 text-sm text-default">
                No fare <span class="text-muted">· trip planners show no price</span>
              </span>
            </label>
          </div>
        </fieldset>

        <div
          :if={@cell.from != @cell.to}
          id="cell-return"
          class="border-t border-subtle pt-3"
        >
          <.fare_checkbox
            id="cell-both"
            name="cell[both]"
            value="true"
            checked={@cell.both?}
            label={"Also for rides from #{@cell.to_name} to #{@cell.from_name}"}
          />
        </div>

        <p :if={@cell.error} id="cell-error" class="text-sm font-semibold text-error-fg">
          {@cell.error}
        </p>
      </.form>

      <:status>
        <p id="cell-status" class="mb-2 text-[13px] text-muted">
          Nothing changes until you save. {export_phrase(@version_name, @published?)}
        </p>
      </:status>
    </.confirm_dialog>
    """
  end

  @doc """
  Renders the route group drawer: the group's name, every route of this version
  as a choice, and the two warnings the prototype shows — the routes this group
  takes out of another group, and the routes that would be left in no group.

  `route_ids` is the whole set of routes the draft holds, because a group is the
  routes it holds rather than a list an editor adds to: a route whose box is
  unticked is removed from the group when the drawer saves.
  """
  attr :draft, :map, required: true
  attr :form, :any, required: true
  attr :workspace, :map, required: true
  attr :version_name, :string, required: true
  attr :published?, :boolean, default: true
  attr :return_focus_id, :string, default: nil
  attr :pending?, :boolean, default: false

  def group_drawer(assigns) do
    assigns =
      assigns
      |> assign(:moving, moved_routes(assigns.draft, assigns.workspace))
      |> assign(:leaving, leaving_routes(assigns.draft, assigns.workspace))

    ~H"""
    <.drawer
      id="group-drawer"
      chrome="planner"
      open
      pending={@pending?}
      on_close="close_group_drawer"
      title={group_drawer_title(@draft)}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
      class="max-w-[560px]"
    >
      <:lede>
        Changes apply to {version_phrase(@version_name, @published?)} as soon as you save.
      </:lede>

      <div id="group-drawer-content" class="flex min-h-0 flex-1 flex-col">
        <.form
          for={@form}
          id="group-form"
          as={:group}
          novalidate
          phx-change="validate_group"
          phx-submit="save_route_group"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.form_error_summary
              id="error-summary"
              title={group_error_summary_title(length(@draft.failures))}
              failures={@draft.failures}
            />

            <.input
              id="group-name"
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="Local routes"
              errors={List.wrap(@draft.name_error)}
              help="As riders know it, such as “Local routes” or “Express”."
              autocomplete="off"
              phx-debounce="300"
            />

            <fieldset id="group-routes" class="min-w-0">
              <legend class="text-sm font-semibold text-strong">Routes</legend>
              <p class="mt-0.5 text-[13px] text-muted">
                A route is in one group. Choosing a route from another group moves it here.
              </p>
              <%!-- The hidden marker says the route list arrived at all: an
                unticked checkbox is absent from a form's payload, so a drawer
                where the operator ticked nothing sends no `route_ids` key unless
                the marker travels with it. A group with no routes is a real
                answer — it is what leaves every route in no group. --%>
              <input type="hidden" name="group[route_ids][]" value="" />
              <div class="mt-2 grid sm:grid-cols-2">
                <label
                  :for={route <- @workspace.routes}
                  for={"group-route-#{route.route_id}"}
                  class="flex min-h-11 cursor-pointer items-center gap-3 py-1"
                >
                  <input
                    type="checkbox"
                    id={"group-route-#{route.route_id}"}
                    name="group[route_ids][]"
                    value={route.route_id}
                    checked={route.route_id in @draft.route_ids}
                    class="size-5 shrink-0 accent-action"
                  />
                  <span class="min-w-0 text-sm text-strong">
                    <RouteIdentity.route_badge route={route} />
                    {route_name(route)}
                    <span :if={other_group_of(route, assigns)} class="block text-[12px] text-muted">
                      In {other_group_of(route, assigns)}
                    </span>
                  </span>
                </label>
              </div>
            </fieldset>

            <.message
              :if={@moving != []}
              id="group-moving"
              kind="warning"
              role="status"
              title="Routes move between groups"
            >
              <b>
                {Enum.map_join(@moving, ", ", &"Route #{&1.route_id}")}
                {if length(@moving) == 1, do: "moves", else: "move"} from {group_name(
                  @workspace,
                  hd(@moving).from_network_id
                )}.
              </b>
              Rides on {if length(@moving) == 1, do: "it", else: "them"} will charge {@draft.name ||
                "this group"}’s fares.
            </.message>

            <.message
              :if={@leaving != []}
              id="group-leaving"
              kind="warning"
              role="status"
              title="Routes left in no group"
            >
              <b>
                {Enum.map_join(@leaving, ", ", &"Route #{&1}")} will be in no group
              </b>
              and have no fare until you add {if length(@leaving) == 1, do: "it", else: "them"} to another group.
            </.message>

            <p class="text-[13px] text-muted">
              In the exported feed a route group is a GTFS network <code class="font-mono text-[12px]">networks.txt, route_networks.txt</code>. The route
              form’s “Fare network” field shows the same choice.
            </p>
          </.drawer_scroll>

          <.drawer_footer>
            <.button
              id="cancel-route-group"
              variant="quiet"
              class="min-h-11"
              phx-click="close_group_drawer"
            >
              Cancel
            </.button>
            <.button
              id="save-route-group"
              variant="primary"
              class="min-h-11"
              type="submit"
              phx-disable-with="Saving…"
            >
              {if @draft.key, do: "Save changes", else: "Create route group"}
            </.button>
          </.drawer_footer>
        </.form>
      </div>
    </.drawer>
    """
  end

  @doc """
  Renders the passes table: one row per pass and one column per route group,
  each cell a checkbox that adds or removes that group from the pass's accepted
  networks.

  A version with no pass carries no table — there is nothing to accept — which
  is what the prototype does.
  """
  attr :workspace, :map, required: true
  attr :version_name, :string, required: true
  attr :published?, :boolean, default: true

  def passes_card(assigns) do
    assigns =
      assign(
        assigns,
        :forms,
        Map.new(pass_fares(assigns.workspace), &{&1.key, to_form(%{}, as: :pass)})
      )

    ~H"""
    <section
      :if={pass_fares(@workspace) != []}
      id="passes-card"
      aria-labelledby="passes-title"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle px-4 py-3 sm:px-5">
        <h2 id="passes-title" class="font-sans text-base font-bold tracking-normal text-strong">
          Passes
        </h2>
        <p class="mt-0.5 text-[13px] text-muted">
          Which route groups accept each pass. A pass covers every ride on those groups; riders
          see it as another way to pay. Changes apply to {version_phrase(@version_name, @published?)} as soon as you save.
        </p>
      </div>

      <div class="overflow-x-auto">
        <table id="passes" class="w-full border-collapse text-sm">
          <caption class="sr-only">Which route groups accept each pass.</caption>
          <thead>
            <tr>
              <th
                scope="col"
                class="border-b border-subtle bg-canvas px-4 py-2 text-left text-[13px] font-semibold text-strong"
              >
                Pass
              </th>
              <th
                :for={group <- @workspace.groups}
                scope="col"
                class="w-[180px] border-b border-subtle bg-canvas px-4 py-2 text-left text-[13px] font-semibold text-strong"
              >
                {group.name || group.network_id}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={fare <- pass_fares(@workspace)} id={"pass-row-#{fare.key}"}>
              <th
                scope="row"
                class="border-b border-subtle px-4 text-left text-sm font-bold text-strong"
              >
                {fare.name}
                <span class="font-normal text-muted">· {fare.price}</span>
              </th>
              <td
                :for={group <- @workspace.groups}
                class="border-b border-subtle px-4"
              >
                <%!-- One form per cell: the checkbox carries the group it belongs
                  to beside its own answer, so a change names the one group that
                  moved rather than the whole row. The hidden marker sends `false`
                  when the box is unticked, because an unticked checkbox is absent
                  from a form's payload. --%>
                <.form
                  for={Map.fetch!(@forms, fare.key)}
                  id={"pass-form-#{fare.key}-#{group.network_id}"}
                  as={:pass}
                  phx-change="set_pass_acceptance"
                  class="flex min-h-11 items-center gap-2"
                >
                  <input type="hidden" name="pass[fare_product_id]" value={fare.key} />
                  <input type="hidden" name="pass[network_id]" value={group.network_id} />
                  <input type="hidden" name="pass[accepted]" value="false" />
                  <label
                    for={"pass-#{fare.key}-#{group.network_id}"}
                    class="flex min-h-11 cursor-pointer items-center gap-2"
                  >
                    <input
                      type="checkbox"
                      id={"pass-#{fare.key}-#{group.network_id}"}
                      name="pass[accepted]"
                      value="true"
                      checked={group.network_id in fare.accepted_network_ids}
                      class="size-5 shrink-0 accent-action"
                    />
                    <span class="text-sm text-default">Accepted</span>
                  </label>
                </.form>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  @doc false
  attr :workspace, :map, required: true

  def time_periods_card(assigns) do
    ~H"""
    <section id="time-periods-card" class="overflow-clip rounded-card border border-subtle bg-white">
      <div class="flex flex-wrap items-start justify-between gap-3 border-b border-subtle px-4 py-3 sm:px-5">
        <div>
          <h2
            id="time-periods-title"
            class="font-sans text-base font-bold tracking-normal text-strong"
          >
            Time periods
          </h2>
          <p :if={@workspace.time_periods == []} class="mt-0.5 text-[13px] text-muted">
            Only needed when a fare costs more or less at some times, such as peak hours.
          </p>
        </div>
        <.button
          id="create-time-period"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="open_time_period_drawer"
        >
          <.icon name="hero-plus" class="size-4" /> Create time period
        </.button>
      </div>
      <p :if={@workspace.time_periods == []} class="px-4 py-4 text-sm text-default sm:px-5">
        Prices are the same at all times of day.
        <span class="text-muted">
          Time periods appear only in the newer GTFS fare format; apps that read the older format always show the all-day price.
        </span>
      </p>
      <ul :if={@workspace.time_periods != []} id="time-periods-list">
        <li
          :for={period <- @workspace.time_periods}
          id={"time-period-#{period.timeframe_group_id}"}
          class="flex flex-wrap items-center gap-x-4 gap-y-1 border-b border-subtle px-4 py-2 last:border-b-0 sm:px-5"
        >
          <span class="text-sm font-bold text-strong">
            {period.name || period.timeframe_group_id}
          </span>
          <span class="text-[13px] text-muted">
            {period_days(period.weekdays)} · {Enum.map_join(
              period.ranges,
              ", ",
              &period_range_text(&1, period)
            )}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  attr :workspace, :map, required: true
  attr :older_allowances, :list, default: []
  attr :has_rules?, :boolean, default: false

  def transfers_tab(assigns) do
    ~H"""
    <div class="grid min-w-0 grid-cols-1 gap-4" id="transfers-tab">
      <section :if={@has_rules?} class="rounded-card border border-subtle bg-white px-4 py-3 sm:px-5">
        <h2 class="text-base font-bold text-strong">Transfers in plain words</h2>
        <ul class="mt-1 grid gap-1 text-sm text-default">
          <li :for={transfer <- @workspace.transfers} :if={transfer.policy}>
            {transfer_sentence(@workspace, transfer)}
          </li>
          <li class="text-muted">Any other change: riders pay a new full fare.</li>
        </ul>
      </section>
      <section
        :if={@has_rules?}
        id="transfer-matrix"
        class="overflow-clip rounded-card border border-subtle bg-white"
      >
        <div class="px-4 py-3 sm:px-5">
          <h2 class="text-base font-bold text-strong">Transfers between route groups</h2>
          <p class="text-[13px] text-muted">
            Rows are the route group a rider leaves; columns are the one they board. Select a cell to change it.
          </p>
        </div>
        <div class="overflow-x-auto px-4 pb-4 sm:px-5">
          <table class="w-full min-w-[520px] border-collapse rounded-card border border-subtle">
            <thead>
              <tr>
                <th class="bg-canvas p-3 text-left text-[12px] text-muted">From ↓ · To →</th>
                <th
                  :for={group <- @workspace.groups}
                  class="border-l border-subtle bg-canvas p-3 text-left text-[13px] font-semibold text-strong"
                >
                  {group.name || group.network_id}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={from <- @workspace.groups}>
                <th scope="row" class="bg-canvas p-3 text-left text-[13px] font-semibold text-strong">
                  {from.name || from.network_id}
                </th>
                <td :for={to <- @workspace.groups} class="border-l border-t border-subtle p-0">
                  <button
                    type="button"
                    class="flex min-h-14 w-full flex-col justify-center px-3 py-2 text-left hover:bg-canvas"
                    phx-click="open_transfer_edit"
                    phx-value-from={from.network_id}
                    phx-value-to={to.network_id}
                    aria-label={"Edit transfer from #{from.name || from.network_id} to #{to.name || to.network_id}"}
                  >
                    <span class="text-sm font-semibold text-strong">
                      {transfer_label(@workspace, from.network_id, to.network_id)}
                    </span>
                    <span class="text-[12px] text-muted">
                      {transfer_limit(@workspace, from.network_id, to.network_id)}
                    </span>
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
      <section class="rounded-card border border-subtle bg-white">
        <div class="border-b border-subtle px-4 py-3 sm:px-5">
          <h2 class="text-base font-bold text-strong">Changes that count as one ride</h2>
          <p class="text-[13px] text-muted">
            For example, two rail lines riders change between inside one station.
          </p>
        </div>
        <p :if={@workspace.joins == []} class="px-4 py-4 text-sm text-default sm:px-5">
          None in this version. Each vehicle a rider boards is a separate ride.<span class="block text-[13px] text-muted">Not editable yet. Imported rules are listed here and exported unchanged.</span>
        </p>
        <ul :if={@workspace.joins != []} class="divide-y divide-subtle">
          <li :for={join <- @workspace.joins} class="px-4 py-3 text-sm text-default">
            {inspect(join)}
          </li>
        </ul>
        <p class="border-t border-subtle px-4 py-3 text-[13px] text-muted sm:px-5">
          fare_leg_join_rules.txt · newer format only
        </p>
      </section>
      <section class="rounded-card border border-subtle bg-white">
        <div class="border-b border-subtle px-4 py-3 sm:px-5">
          <h2 class="text-base font-bold text-strong">In the older GTFS fare format</h2>
          <p class="text-[13px] text-muted">
            That format stores one transfer allowance on each fare, for any route.
          </p>
        </div>
        <ul>
          <li
            :for={fare <- @workspace.fares}
            class="flex flex-wrap items-center gap-x-4 border-b border-subtle px-4 py-2 last:border-b-0 sm:px-5"
          >
            <span class="min-w-[160px] text-sm font-bold text-strong">{fare.name}</span><span class="text-sm text-default">{older_allowance(@older_allowances, fare.name)}</span>
          </li>
        </ul>
        <p class="border-t border-subtle px-4 py-3 text-[13px] text-muted sm:px-5">
          The older format cannot describe transfers between route groups or pay-the-difference rules.
        </p>
      </section>
      <section
        :if={!@has_rules?}
        id="transfers-empty"
        class="rounded-card border border-subtle bg-white px-5 py-6"
      >
        <h2 class="text-base font-bold text-strong">Riders pay a new fare every time they board</h2>
        <p class="mt-1 text-sm text-muted">
          Add a transfer rule if riders can change vehicles for free or for less.
        </p>
        <.button id="add-first-transfer-rule" class="mt-4 min-h-11" phx-click="open_transfer_create">
          Add first transfer rule
        </.button>
      </section>
    </div>
    """
  end

  attr :checks, :map, required: true
  attr :version_id, :string, required: true

  def fares_checks_tab(assigns) do
    ~H"""
    <section id="fare-problems" class="overflow-clip rounded-card border border-subtle bg-white">
      <header class="border-b border-subtle px-4 py-3 sm:px-5">
        <h2 class="text-base font-bold text-strong">Fare checks</h2>
        <p class="mt-1 text-[13px] text-muted">Problems and notes found in this version’s fares.</p>
      </header>
      <ul
        :if={@checks.repair == [] and @checks.review == [] and @checks.notes == []}
        id="fare-checks-clear"
        class="px-4 py-4 text-sm text-default sm:px-5"
      >
        <li>All fare checks passed.</li>
      </ul>
      <ul
        :if={@checks.repair != [] or @checks.review != [] or @checks.notes != []}
        class="divide-y divide-subtle"
      >
        <li
          :for={
            {finding, tone} <-
              Enum.map(@checks.repair, &{&1, :error}) ++
                Enum.map(@checks.review, &{&1, :warning}) ++ Enum.map(@checks.notes, &{&1, :note})
          }
          class="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-start sm:justify-between sm:px-5"
        >
          <div class="min-w-0">
            <p class="text-sm font-semibold text-strong">{finding.title}</p>
            <p class="mt-1 text-[13px] text-muted">{finding.body}</p>
          </div>
          <.link
            :if={finding.action && finding.tab}
            navigate={checks_action_path(@version_id, finding.tab)}
            class={[
              "min-h-10 shrink-0 rounded-control border px-3 py-2 text-sm font-semibold",
              check_tone_class(tone)
            ]}
          >
            {finding.action}
          </.link>
        </li>
      </ul>
      <details
        :if={@checks.passed != []}
        class="border-t border-subtle px-4 py-3 text-sm text-default sm:px-5"
      >
        <summary class="cursor-pointer font-semibold text-strong">
          {length(@checks.passed)} checks passed
        </summary>
        <ul class="mt-2 grid gap-1 text-[13px] text-muted">
          <li :for={message <- @checks.passed}>{message}</li>
        </ul>
      </details>
    </section>
    """
  end

  attr :workspace, :map, required: true
  attr :form, :any, required: true
  attr :routes, :list, required: true
  attr :stops, :list, required: true
  attr :result, :any, default: nil
  attr :note, :string, default: nil

  def journey_check(assigns) do
    ~H"""
    <section
      id="journey-check"
      class="grid min-w-0 gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(280px,0.72fr)]"
    >
      <div class="rounded-card border border-subtle bg-white p-4 sm:p-5">
        <h2 class="text-base font-bold text-strong">Check a journey</h2>
        <p class="mt-1 text-[13px] text-muted">
          Choose a rider, then add the rides and boarding times in order.
        </p>
        <.form for={@form} id="journey-check-form" phx-change="price_journey" class="mt-4 grid gap-3">
          <label class="grid gap-1 text-sm font-medium text-strong" for="journey-rider">
            Rider type
            <select
              id="journey-rider"
              name="journey[rider_category_id]"
              class="min-h-11 rounded-control border border-subtle bg-white px-3 text-sm text-strong"
            >
              <option
                :for={rider <- @workspace.riders}
                value={rider.rider_category_id}
                selected={@form[:rider_category_id].value == rider.rider_category_id}
              >
                {rider.name}
              </option>
            </select>
          </label>
          <label
            :if={@workspace.media != []}
            class="grid gap-1 text-sm font-medium text-strong"
            for="journey-media"
          >
            Fare medium
            <select
              id="journey-media"
              name="journey[fare_media_id]"
              class="min-h-11 rounded-control border border-subtle bg-white px-3 text-sm text-strong"
            >
              <option value="">Any medium</option>
              <option
                :for={medium <- @workspace.media}
                value={medium.fare_media_id}
                selected={@form[:fare_media_id].value == medium.fare_media_id}
              >
                {medium.name}
              </option>
            </select>
          </label>
          <label class="grid gap-1 text-sm font-medium text-strong" for="journey-service-date">
            Service date
            <input
              id="journey-service-date"
              type="date"
              name="journey[service_date]"
              value={@form[:service_date].value}
              class="min-h-11 rounded-control border border-subtle bg-white px-3 text-sm text-strong"
            />
          </label>
          <div id="journey-legs" class="grid gap-3">
            <fieldset
              :for={{leg, index} <- Enum.with_index(@form[:legs].value || [])}
              class="grid gap-2 rounded-control border border-subtle p-3 sm:grid-cols-2"
            >
              <legend class="px-1 text-[13px] font-semibold text-strong">Ride {index + 1}</legend>
              <label class="grid gap-1 text-[13px] text-muted">
                Route
                <select
                  id={"journey-route-#{index}"}
                  name={"journey[legs][#{index}][route_id]"}
                  class="min-h-10 rounded-control border border-subtle bg-white px-2 text-sm text-strong"
                >
                  <option
                    :for={route <- @routes}
                    value={route.route_id}
                    selected={leg["route_id"] == route.route_id}
                  >
                    {route_label(route)}
                  </option>
                </select>
              </label>
              <label class="grid gap-1 text-[13px] text-muted">
                Boards at
                <input
                  type="time"
                  name={"journey[legs][#{index}][departs]"}
                  value={leg["departs"]}
                  class="min-h-10 rounded-control border border-subtle bg-white px-2 text-sm text-strong"
                />
              </label>
              <label class="grid gap-1 text-[13px] text-muted">
                From
                <select
                  id={"journey-from-#{index}"}
                  name={"journey[legs][#{index}][from_stop_id]"}
                  class="min-h-10 rounded-control border border-subtle bg-white px-2 text-sm text-strong"
                >
                  <option
                    :for={stop <- @stops}
                    value={stop.stop_id}
                    selected={leg["from_stop_id"] == stop.stop_id}
                  >
                    {stop.stop_name || stop.stop_id}
                  </option>
                </select>
              </label>
              <label class="grid gap-1 text-[13px] text-muted">
                To
                <select
                  id={"journey-to-#{index}"}
                  name={"journey[legs][#{index}][to_stop_id]"}
                  class="min-h-10 rounded-control border border-subtle bg-white px-2 text-sm text-strong"
                >
                  <option
                    :for={stop <- @stops}
                    value={stop.stop_id}
                    selected={leg["to_stop_id"] == stop.stop_id}
                  >
                    {stop.stop_name || stop.stop_id}
                  </option>
                </select>
              </label>
              <button
                :if={index > 0}
                type="button"
                class="min-h-10 justify-self-start text-sm font-semibold text-link"
                phx-click="remove_journey_leg"
                phx-value-index={index}
              >
                Remove ride
              </button>
            </fieldset>
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              :if={length(@form[:legs].value || []) < 3}
              id="journey-add-leg"
              type="button"
              class="min-h-11 rounded-control border border-subtle px-3 text-sm font-semibold text-strong hover:bg-canvas"
              phx-click="add_journey_leg"
            >
              Add another ride
            </button>
            <button
              id="journey-save-test"
              type="button"
              class="min-h-11 rounded-control bg-primary px-4 text-sm font-semibold text-white hover:brightness-95"
              phx-click="save_test_journey"
              disabled={is_nil(@result) or is_nil(@result.total)}
            >
              Save as test journey
            </button>
          </div>
        </.form>
        <p :if={@note} id="journey-note" role="status" class="mt-3 text-sm text-default">{@note}</p>
      </div>
      <div
        id="journey-result"
        aria-live="polite"
        class="rounded-card border border-subtle bg-canvas p-4 sm:p-5 lg:sticky lg:top-4 lg:self-start"
      >
        <h3 class="text-[13px] font-semibold uppercase tracking-wide text-muted">Expected fare</h3>
        <p :if={@result && @result.total} class="mt-2 text-3xl font-bold text-strong">
          {money_text(@result.total, @workspace.currency)}
        </p>
        <p :if={is_nil(@result) or is_nil(@result.total)} class="mt-2 text-xl font-bold text-strong">
          Price unknown
        </p>
        <ul :if={@result} class="mt-3 grid gap-2 text-sm text-default">
          <li :for={leg <- @result.legs} class="flex justify-between gap-3">
            <span>Ride {leg.index}: {leg.product_name || leg.reason || "Fare not found"}</span><span>{money_text(leg.charged, @workspace.currency)}</span>
          </li>
        </ul>
        <p :if={@result && @result.problems != []} class="mt-3 text-[13px] text-muted">
          {Enum.join(@result.problems, " · ")}
        </p>
        <p class="mt-3 text-[12px] text-muted">
          Approximation: each ride arrives when it boards, so transfer limits use the spacing between boarding times.
        </p>
      </div>
    </section>
    """
  end

  attr :journeys, :list, required: true
  attr :currency, :string, required: true

  def saved_journeys(assigns) do
    ~H"""
    <section id="saved-journeys" class="overflow-clip rounded-card border border-subtle bg-white">
      <header class="border-b border-subtle px-4 py-3 sm:px-5">
        <h2 class="text-base font-bold text-strong">Saved test journeys</h2>
      </header>
      <p :if={@journeys == []} class="px-4 py-4 text-sm text-muted sm:px-5">
        Save a journey to see when fare changes affect its expected price.
      </p>
      <ul :if={@journeys != []} class="divide-y divide-subtle">
        <li
          :for={journey <- @journeys}
          class="flex flex-wrap items-center justify-between gap-3 px-4 py-3 sm:px-5"
        >
          <div>
            <p class="text-sm font-semibold text-strong">{journey.name}</p>
            <p class="text-[13px] text-muted">
              Expected {money_text(journey.expected_amount, @currency)} · current {if journey.current_amount,
                do: money_text(journey.current_amount, @currency),
                else: "unknown"}
            </p>
          </div>
          <div class="flex items-center gap-2">
            <span
              :if={journey.changed?}
              class="rounded-full bg-warning-subtle px-2.5 py-1 text-[12px] font-semibold text-warning"
            >
              Price changed
            </span>
            <button
              type="button"
              class="min-h-10 rounded-control border border-subtle px-3 text-sm font-semibold text-strong"
              phx-click="open_saved_journey"
              phx-value-journey_id={journey.id}
            >
              Check again
            </button>
            <button
              :if={journey.changed? && journey.current_amount}
              type="button"
              class="min-h-10 rounded-control bg-primary px-3 text-sm font-semibold text-white"
              phx-click="accept_journey_price"
              phx-value-journey_id={journey.id}
              phx-value-amount={journey.current_amount}
            >
              Accept new price
            </button>
          </div>
        </li>
      </ul>
    </section>
    """
  end

  attr :counts, :map, required: true

  def formats_section(assigns) do
    ~H"""
    <section id="formats" class="rounded-card border border-subtle bg-white p-4 sm:p-5">
      <h2 class="text-base font-bold text-strong">What the exported feed includes</h2>
      <p class="mt-1 text-[13px] text-muted">
        Counts reflect the current version’s GTFS fare tables.
      </p>
      <dl class="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
        <div :for={{label, count} <- @counts} class="rounded-control border border-subtle p-3">
          <dt class="text-[12px] text-muted">{label}</dt>
          <dd class="mt-1 text-xl font-bold text-strong">{count}</dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :draft, :map, required: true
  attr :workspace, :map, required: true
  attr :scope, :map, required: true
  attr :form, :any, required: true
  attr :version_name, :string, required: true
  attr :published?, :boolean, default: false
  attr :return_focus_id, :string, default: nil
  attr :pending?, :boolean, default: false

  def transfer_drawer(assigns) do
    assigns =
      assign(
        assigns,
        :difference_allowed?,
        Transfers.difference_allowed?(
          assigns.scope,
          assigns.draft.from,
          assigns.draft.to
        )
      )

    ~H"""
    <.drawer
      id="transfer-drawer"
      open={true}
      modal={true}
      title={"Transfer from #{group_name(@workspace, @draft.from)} to #{group_name(@workspace, @draft.to)}"}
      on_close="close_transfer_drawer"
      return_focus_id={@return_focus_id}
      pending={@pending?}
    >
      <.form for={@form} id="transfer-form" phx-change="change_transfer" phx-submit="save_transfer">
        <.drawer_scroll>
          <div
            :if={@draft.failures != []}
            id="transfer-error"
            role="alert"
            class="rounded-card border border-error-line bg-error-soft px-4 py-3 text-sm text-error-fg"
          >
            <p :for={failure <- @draft.failures}>{failure}</p>
          </div>
          <.choice_cards
            id="transfer-pay"
            name="transfer[pay]"
            type="radio"
            label="What does the rider pay for the next ride?"
            options={[
              %{value: "free", label: "Nothing", description: "The change is free."},
              %{
                value: "difference",
                label: "The difference",
                description: "Only the extra cost when the next fare is higher.",
                disabled?: not @difference_allowed?
              },
              %{
                value: "fee",
                label: "A transfer fee",
                description: "A fixed amount instead of the next fare."
              },
              %{
                value: "full",
                label: "A new full fare",
                description: "No discount. This is what happens without a rule."
              }
            ]}
            selected={[@draft.pay]}
          />
          <p
            :if={!@difference_allowed?}
            id="transfer-difference-reason"
            class="text-[13px] text-muted"
          >
            This pair cannot express a difference without undercharging a rider.
          </p>
          <div :if={@draft.pay != "full"} class="mt-5 grid gap-4">
            <div class="grid gap-4 sm:grid-cols-[160px_minmax(0,1fr)]">
              <label class="grid gap-1 text-sm font-semibold">
                Time limit
                <span class="flex items-center gap-2">
                  <.input
                    field={@form[:minutes]}
                    type="number"
                    min="0"
                    class="min-h-11 w-24 rounded-control border border-control bg-white px-3 py-2 text-sm text-default focus-visible:outline-2 focus-visible:outline-focus"
                  />
                  <span class="font-normal text-muted">minutes</span>
                </span>
              </label>
              <label class="grid gap-1 text-sm font-semibold">
                Counted from
                <.input
                  field={@form[:basis]}
                  type="select"
                  options={[
                    {"1", "First boarding to boarding the next vehicle"},
                    {"0", "First boarding to getting off the last vehicle"},
                    {"2", "Getting off to boarding the next vehicle"},
                    {"3", "Getting off to getting off the next vehicle"}
                  ]}
                />
                <span class="text-[13px] font-normal text-muted">
                  Most agencies count from first boarding. The older format can only count that way.
                </span>
              </label>
            </div>
            <label :if={@draft.from == @draft.to} class="grid gap-1 text-sm font-semibold">
              How many changes
              <.input
                field={@form[:count]}
                type="select"
                options={[{"1", "1"}, {"2", "2"}, {"-1", "No limit"}]}
              />
            </label>
            <p :if={@draft.from != @draft.to} class="text-[13px] text-muted">
              A change between two different route groups covers one change. Add another rule for the next group.
            </p>
            <label :if={@draft.pay == "fee"} class="grid gap-1 text-sm font-semibold">
              Transfer fee <.input field={@form[:fee]} type="number" step="0.01" />
            </label>
          </div>
        </.drawer_scroll>
        <.drawer_footer>
          <p class="basis-full text-[13px] text-muted">
            Changes apply to {@version_name} service as soon as you save.
          </p>
          <.button
            id="cancel-transfer"
            type="button"
            variant="quiet"
            class="min-h-11"
            phx-click="close_transfer_drawer"
          >
            Cancel
          </.button>
          <.button id="save-transfer" type="submit" class="min-h-11">Save transfer rule</.button>
        </.drawer_footer>
      </.form>
    </.drawer>
    """
  end

  defp transfer_label(workspace, from, to) do
    case Enum.find(
           workspace.transfers,
           &(&1.from_leg_group_id == from and &1.to_leg_group_id == to)
         ) do
      %{policy: %{pay: :free}} -> "Free"
      %{policy: %{pay: :fee}} -> "Transfer fee"
      %{policy: %{pay: :difference}} -> "Pays the difference"
      _ -> "New full fare"
    end
  end

  defp transfer_limit(workspace, from, to) do
    case Enum.find(
           workspace.transfers,
           &(&1.from_leg_group_id == from and &1.to_leg_group_id == to)
         ) do
      %{policy: %{minutes: minutes}} when is_integer(minutes) -> "Within #{minutes} minutes"
      _ -> "No transfer rule"
    end
  end

  defp transfer_sentence(workspace, transfer) do
    "Changing from #{group_name(workspace, transfer.from_leg_group_id)} to #{group_name(workspace, transfer.to_leg_group_id)}: #{transfer_label(workspace, transfer.from_leg_group_id, transfer.to_leg_group_id)} within #{transfer.policy.minutes || 0} minutes."
  end

  defp older_allowance(rows, fare_name) do
    fare_id = Identifier.normalize(fare_name)

    case Enum.find(rows, &(&1.fare_id == fare_id)) do
      %{transfers: 0} ->
        "No free transfers"

      %{transfers: nil} ->
        "Unlimited transfers"

      %{transfers: count, transfer_duration: duration} when is_integer(count) ->
        "#{count} free #{if count == 1, do: "transfer", else: "transfers"}#{if duration, do: " within #{div(duration, 60)} min", else: ""}"

      _ ->
        "No older-format allowance"
    end
  end

  attr :rules, :list, required: true
  attr :workspace, :map, required: true
  attr :show_ids?, :boolean, default: false

  def rule_list_card(assigns) do
    ~H"""
    <details id="rule-list" class="overflow-clip rounded-card border border-subtle bg-white">
      <summary class="flex min-h-12 cursor-pointer items-center gap-2 px-4 py-3 sm:px-5">
        <.icon name="hero-chevron-right" class="size-4" />
        <span class="text-sm font-bold text-strong">All fare rules as a list</span>
        <span class="text-sm text-muted">· {length(@rules)}</span>
      </summary>
      <div class="border-t border-subtle">
        <div class="flex flex-wrap items-center gap-3 border-b border-subtle px-4 py-2 sm:px-5">
          <p class="flex-1 text-[13px] text-muted">
            The same rules as the tables above, one sentence each. The most specific rule wins: a route group beats any route, a zone beats any zone.
          </p>
          <label
            for="show-rule-feed-ids"
            class="inline-flex min-h-11 cursor-pointer items-center gap-2 text-sm"
          >
            <input
              id="show-rule-feed-ids"
              type="checkbox"
              class="size-5 accent-action"
              phx-click="toggle_rule_feed_ids"
              checked={@show_ids?}
              aria-controls="fare-rules"
            /> Show feed IDs
          </label>
        </div>
        <div class="overflow-x-auto">
          <table id="fare-rules" class="w-full border-collapse">
            <caption class="sr-only">Fare rules and their adult prices.</caption>
            <thead>
              <tr class="text-left">
                <th
                  scope="col"
                  class="border-b border-subtle bg-canvas px-4 py-2 text-[13px] font-semibold text-strong"
                >
                  Rule
                </th>
                <th
                  scope="col"
                  class="border-b border-subtle bg-canvas px-4 py-2 text-right text-[13px] font-semibold text-strong"
                >
                  Adult
                </th>
                <th scope="col" class="border-b border-subtle bg-canvas px-2 py-2">
                  <span class="sr-only">Actions</span>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={rule <- @rules} id={"fare-rule-#{rule.id}"} class="hover:bg-canvas/60">
                <td class="border-b border-subtle px-4 py-2.5 text-sm text-default">
                  {fare_rule_sentence(rule, @workspace)}
                  <code :if={@show_ids?} class="mt-1 block break-all font-mono text-[12px] text-muted">
                    {rule_ids_text(rule)}
                  </code>
                </td>
                <td class="border-b border-subtle px-4 text-right text-sm font-semibold tabular-nums text-strong">
                  {fare_rule_price(rule, @workspace)}
                </td>
                <td class="border-b border-subtle px-2 text-right">
                  <.button
                    :if={rule.editable?}
                    id={"edit-fare-rule-#{rule.id}"}
                    type="button"
                    variant="quiet"
                    class="min-h-11"
                    phx-click="open_rule_drawer"
                    phx-value-rule_id={rule.id}
                    aria-label={"Edit rule: #{fare_rule_sentence(rule, @workspace)}"}
                  >
                    Edit rule
                  </.button>
                  <span :if={!rule.editable?} class="px-2 text-[12px] text-muted">
                    Managed by Passes table
                  </span>
                </td>
              </tr>
              <tr :if={@rules == []} id="fare-rules-empty">
                <td colspan="3" class="px-4 py-4 text-sm text-muted">
                  No fare rules in this version.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </details>
    """
  end

  attr :draft, :map, required: true
  attr :form, :any, required: true
  attr :version_name, :string, required: true
  attr :published?, :boolean, default: true
  attr :return_focus_id, :string, default: nil
  attr :pending?, :boolean, default: false

  def time_period_drawer(assigns) do
    ~H"""
    <.drawer
      id="time-period-drawer"
      chrome="planner"
      open
      pending={@pending?}
      on_close="close_time_period_drawer"
      title="Create time period"
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
      class="max-w-[780px]"
    >
      <:lede>{version_phrase(@version_name, @published?)}</:lede>
      <.form
        for={@form}
        id="time-period-form"
        as={:time_period}
        novalidate
        phx-change="change_time_period"
        phx-submit="save_time_period"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.drawer_scroll>
          <.form_error_summary
            id="time-period-error-summary"
            title="Fix these problems to save"
            failures={@draft.failures}
          />
          <.input
            id="time-period-name"
            field={@form[:name]}
            type="text"
            label="Name"
            value={@draft.name}
            placeholder="Weekday peak"
            autocomplete="off"
            class="min-h-11"
            help="For your team; riders see the fare, not this name."
          />
          <fieldset id="time-period-weekdays" class="grid gap-2">
            <legend class="text-sm font-semibold text-strong">Days</legend>
            <div class="flex flex-wrap gap-1.5">
              <label
                :for={{day, label} <- weekday_choices()}
                for={"time-period-day-#{day}"}
                class="flex min-h-11 min-w-12 cursor-pointer items-center justify-center rounded-control border border-control px-3 text-sm font-semibold text-strong has-[:checked]:border-action has-[:checked]:bg-selection has-[:checked]:text-action has-[:focus-visible]:outline has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-focus"
              >
                <input
                  type="checkbox"
                  id={"time-period-day-#{day}"}
                  name="time_period[weekdays][]"
                  value={day}
                  checked={day in @draft.days}
                  class="sr-only"
                />{label}
              </label>
            </div>
            <p class="text-[13px] text-muted">
              Leave all days clear for every day. Holidays count as the day they fall on. The export adds a calendar used only by fares, so changing trip calendars never changes a fare.
            </p>
          </fieldset>
          <fieldset id="time-period-ranges" class="grid gap-2">
            <legend class="text-sm font-semibold text-strong">Times</legend>
            <p class="text-[13px] text-muted">
              A ride is in this period when it starts between these times.
            </p>
            <div
              :for={{range, index} <- Enum.with_index(@draft.ranges)}
              id={"time-period-range-#{index}"}
              class="grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-end gap-2 sm:flex sm:flex-wrap sm:items-end"
            >
              <.input
                id={"time-period-range-#{index}-start"}
                field={@form[:name]}
                name={"time_period[ranges][#{index}][start_time]"}
                type="time"
                label={"Range #{index + 1} starts"}
                value={range.start_time}
                class="min-h-11"
              />
              <span class="pb-3 text-sm text-muted">to</span>
              <.input
                id={"time-period-range-#{index}-end"}
                field={@form[:name]}
                name={"time_period[ranges][#{index}][end_time]"}
                type="time"
                label={"Range #{index + 1} ends"}
                value={range.end_time}
                class="min-h-11"
              />
              <label
                :if={index == length(@draft.ranges) - 1}
                for="time-period-until-end"
                class="col-span-3 flex min-h-11 cursor-pointer items-center gap-2 text-sm sm:ml-2"
              >
                <input type="hidden" name="time_period[until_end_of_day]" value="false" />
                <input
                  id="time-period-until-end"
                  type="checkbox"
                  name="time_period[until_end_of_day]"
                  value="true"
                  checked={@draft.until_end_of_day?}
                  class="size-5 accent-action"
                />Until end of service day
              </label>
              <.button
                :if={length(@draft.ranges) > 1}
                id={"remove-time-period-range-#{index}"}
                type="button"
                variant="quiet"
                class="col-span-3 min-h-11 text-error-fg sm:ml-2"
                phx-click="remove_time_period_range"
                phx-value-index={index}
              >
                Remove time range
              </.button>
            </div>
            <.button
              id="add-time-period-range"
              type="button"
              variant="quiet"
              class="min-h-11 justify-self-start"
              phx-click="add_time_period_range"
            >
              <.icon name="hero-plus" class="size-4" /> Add time range
            </.button>
          </fieldset>
          <div
            id="time-period-result"
            aria-live="polite"
            class="grid gap-1 rounded-card border border-subtle bg-canvas px-4 py-3"
          >
            <p class="text-[13px] text-muted">What this period covers</p>
            <p class="text-xl font-bold text-strong">{period_days(@draft.weekdays)}</p>
            <p class="text-sm text-default">Rides that start {draft_ranges_text(@draft)}.</p>
            <p class="text-sm font-semibold text-strong">
              Next, add a fare rule that uses it, for example a higher Intercity fare in the weekday peak.
            </p>
          </div>
          <.message kind="neutral" title="Apps that read only the older format show the all-day price">
            Time periods exist only in the newer GTFS fare format.
          </.message>
        </.drawer_scroll>
        <.drawer_footer>
          <p class="basis-full text-[13px] text-muted">
            Changes apply to {version_phrase(@version_name, @published?)} as soon as you save.
          </p>
          <.button
            id="cancel-time-period"
            type="button"
            variant="quiet"
            class="min-h-11"
            phx-click="close_time_period_drawer"
          >
            Cancel
          </.button>
          <.button id="save-time-period" type="submit" class="min-h-11" phx-disable-with="Saving…">
            Create time period
          </.button>
        </.drawer_footer>
      </.form>
    </.drawer>
    """
  end

  attr :draft, :map, required: true
  attr :form, :any, required: true
  attr :workspace, :map, required: true
  attr :rules, :list, required: true
  attr :overlaps, :list, required: true
  attr :version_name, :string, required: true
  attr :published?, :boolean, default: true
  attr :return_focus_id, :string, default: nil
  attr :pending?, :boolean, default: false

  def rule_drawer(assigns) do
    ~H"""
    <.drawer
      id="rule-drawer"
      chrome="planner"
      open
      pending={@pending?}
      on_close="close_rule_drawer"
      title={if @draft.rule_id, do: "Edit fare rule", else: "Add fare rule"}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
      class="max-w-[780px]"
    >
      <:lede>{version_phrase(@version_name, @published?)}</:lede>
      <.form
        for={@form}
        id="rule-form"
        as={:rule}
        novalidate
        phx-change="change_rule"
        phx-submit="save_rule"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.drawer_scroll>
          <.form_error_summary
            id="rule-error-summary"
            title="Fix these problems to save"
            failures={@draft.failures}
          />
          <input :if={@draft.rule_id} type="hidden" name="rule[rule_id]" value={@draft.rule_id} />
          <section class="grid gap-3">
            <.step_head id="rule-step-1" number={1} title="Which rides?">
              Leave a choice on “Any” when it doesn’t change the fare.
            </.step_head>
            <div class="grid gap-3 pl-0 sm:pl-10">
              <label for="rule-network" class="grid gap-1 text-sm font-semibold text-strong">
                Route group
                <select id="rule-network" name="rule[network_id]" class="select min-h-11 w-full">
                  <option value="">Any route group</option>
                  <option
                    :for={group <- @workspace.groups}
                    value={group.network_id}
                    selected={@draft.network_id == group.network_id}
                  >
                    {group.name || group.network_id}
                  </option>
                </select>
              </label>
              <div class="grid gap-3 sm:grid-cols-2">
                <label for="rule-from-area" class="grid gap-1 text-sm font-semibold text-strong">
                  Starts in
                  <select id="rule-from-area" name="rule[from_area_id]" class="select min-h-11 w-full">
                    <option value="">Any zone</option>
                    <option
                      :for={zone <- rule_zones(@workspace)}
                      value={zone.area_id}
                      selected={@draft.from_area_id == zone.area_id}
                    >
                      {zone.name}
                    </option>
                  </select>
                </label>
                <label for="rule-to-area" class="grid gap-1 text-sm font-semibold text-strong">
                  Ends in
                  <select id="rule-to-area" name="rule[to_area_id]" class="select min-h-11 w-full">
                    <option value="">Any zone</option>
                    <option
                      :for={zone <- rule_zones(@workspace)}
                      value={zone.area_id}
                      selected={@draft.to_area_id == zone.area_id}
                    >
                      {zone.name}
                    </option>
                  </select>
                </label>
              </div>
              <label for="rule-time-period" class="grid gap-1 text-sm font-semibold text-strong">
                When
                <select
                  id="rule-time-period"
                  name="rule[from_timeframe_group_id]"
                  class="select min-h-11 w-full disabled:bg-canvas disabled:text-muted"
                  disabled={@workspace.time_periods == []}
                >
                  <option value="">Any time</option>
                  <option
                    :for={period <- @workspace.time_periods}
                    value={period.timeframe_group_id}
                    selected={@draft.from_timeframe_group_id == period.timeframe_group_id}
                  >
                    {period.name || period.timeframe_group_id}
                  </option>
                </select>
                <span
                  :if={@workspace.time_periods == []}
                  id="rule-time-disabled-reason"
                  class="text-[13px] font-normal text-muted"
                >
                  No time periods yet. Create one on the Where fares apply tab if a fare costs more at some times.
                </span>
              </label>
              <label
                :if={
                  @draft.from_area_id && @draft.to_area_id && @draft.from_area_id != @draft.to_area_id &&
                    is_nil(@draft.rule_id)
                }
                for="rule-both-directions"
                class="flex min-h-11 cursor-pointer items-center gap-2 text-sm text-strong"
              >
                <input type="hidden" name="rule[both]" value="false" /><input
                  id="rule-both-directions"
                  type="checkbox"
                  name="rule[both]"
                  value="true"
                  checked={@draft.both?}
                  class="size-5 accent-action"
                />
                Also for rides from {zone_name(@workspace, @draft.to_area_id)} to {zone_name(
                  @workspace,
                  @draft.from_area_id
                )}
              </label>
            </div>
          </section>
          <section class="grid gap-3">
            <.step_head id="rule-step-2" number={2} title="Which fare do they pay?" />
            <fieldset id="rule-fares" class="grid gap-1 pl-0 sm:pl-10">
              <legend class="sr-only">Choose the single-ride fare</legend>
              <label
                :for={fare <- single_fares(@workspace)}
                class="flex min-h-11 cursor-pointer items-center gap-3 rounded-control px-2 has-[:checked]:bg-selection"
              >
                <input
                  type="radio"
                  name="rule[fare_product_id]"
                  id={"rule-fare-#{fare.key}"}
                  value={fare.key}
                  checked={@draft.fare_product_id == fare.key}
                  class="size-4 accent-action"
                /><span class="flex-1 text-sm font-semibold text-strong">{fare.name}</span><span class="text-sm tabular-nums text-default">{fare.price}</span>
              </label>
              <p
                :if={Enum.any?(@draft.failures, &(&1.href == "#rule-fares"))}
                id="rule-fare-error"
                class="text-sm font-semibold text-error-fg"
              >
                Choose the fare these rides pay.
              </p>
              <p class="mt-1 text-[13px] text-muted">
                Passes aren’t listed: choose where a pass is accepted in the Passes table.
              </p>
            </fieldset>
          </section>
          <section
            :if={@overlaps != []}
            id="rule-overlap"
            role="alert"
            class="grid gap-2 rounded-card bg-warning-bg px-4 py-3 text-warning-fg"
          >
            <div class="flex items-start gap-2">
              <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
              <div>
                <p class="text-sm font-bold">
                  These rides already pay {Enum.map_join(
                    @overlaps,
                    ", ",
                    &rule_fare_name(&1, @workspace)
                  )}
                </p>
                <p class="mt-0.5 text-sm">
                  A rider can’t be charged two single-ride fares for the same ride.
                </p>
              </div>
            </div>
            <div class="grid gap-1 text-default">
              <label class="flex min-h-11 cursor-pointer items-start gap-3 rounded-control bg-white px-3 py-2">
                <input
                  id="rule-overlap-replace"
                  type="radio"
                  name="rule[overlap]"
                  value="replace"
                  checked={@draft.overlap == :replace}
                  class="mt-1 size-4 accent-action"
                />
                <span>
                  <span class="block text-sm font-semibold text-strong">
                    Replace {Enum.map_join(@overlaps, ", ", &rule_fare_name(&1, @workspace))} with {rule_fare_name(
                      @draft.fare_product_id,
                      @workspace
                    )}
                  </span>
                  <span class="block text-[13px] text-muted">
                    The existing rule changes. Recommended.
                  </span>
                </span>
              </label>
              <label class="flex min-h-11 cursor-pointer items-start gap-3 rounded-control bg-white px-3 py-2">
                <input
                  id="rule-overlap-keep"
                  type="radio"
                  name="rule[overlap]"
                  value="keep_both"
                  checked={@draft.overlap == :keep_both}
                  class="mt-1 size-4 accent-action"
                />
                <span>
                  <span class="block text-sm font-semibold text-strong">Keep both fares</span><span class="block text-[13px] text-muted">Trip planners show both prices and riders may be unsure which applies.</span>
                </span>
              </label>
            </div>
            <p
              :if={Enum.any?(@draft.failures, &(&1.href == "#rule-overlap"))}
              id="rule-overlap-error"
              class="text-sm font-semibold"
            >
              Choose whether to replace the existing fare or keep both.
            </p>
          </section>
          <div
            id="rule-result"
            aria-live="polite"
            class="rounded-card border border-subtle bg-canvas px-4 py-3"
          >
            <p class="text-[13px] text-muted">What this rule does</p>
            <p class="mt-1 text-sm text-strong">{rule_draft_sentence(@draft, @workspace)}</p>
          </div>
        </.drawer_scroll>
        <.drawer_footer>
          <.button
            :if={@draft.rule_id}
            id="delete-fare-rule"
            type="button"
            variant="quiet"
            class="mr-auto min-h-11 text-error-fg"
            phx-click="delete_rule"
            phx-value-rule_id={@draft.rule_id}
            phx-disable-with="Removing…"
          >
            <.icon name="hero-trash" class="size-4" /> Delete rule
          </.button>
          <p class="basis-full text-[13px] text-muted">
            Changes apply to {version_phrase(@version_name, @published?)} as soon as you save.
          </p>
          <.button
            id="cancel-rule"
            type="button"
            variant="quiet"
            class="min-h-11"
            phx-click="close_rule_drawer"
          >
            Cancel
          </.button>
          <.button id="save-rule" type="submit" class="min-h-11" phx-disable-with="Saving…">
            {rule_save_label(@draft, @overlaps, @workspace)}
          </.button>
        </.drawer_footer>
      </.form>
    </.drawer>
    """
  end

  @doc false
  # One route badge in the groups table. The badge is the same component the
  # Routes page draws, so a route's colour cannot differ between the two.
  attr :route, :map, required: true

  defp route_badges(assigns) do
    ~H"""
    <span data-group-badge={@route.route_id}>
      <RouteIdentity.route_badge route={@route} />
    </span>
    """
  end

  defp route_count_text(1), do: "1 route"
  defp route_count_text(count), do: "#{count} routes"

  defp group_route_badges(group, workspace) do
    Enum.map(group.route_ids, &route_of(workspace, &1)) |> Enum.reject(&is_nil/1)
  end

  defp route_of(workspace, route_id) do
    Enum.find(workspace.routes, &(&1.route_id == route_id))
  end

  defp route_name(route) do
    Enum.find_value([route.route_short_name, route.route_long_name], fn value ->
      if is_binary(value) and String.trim(value) != "", do: value
    end) || route.route_id
  end

  # The version's routes no group holds, which is the "In no group" row's own
  # list. A `route_networks` row names a route a `routes.txt` row does not is
  # not drawn: the badge needs a colour the version has.
  defp loose_routes(workspace) do
    grouped = MapSet.new(Enum.flat_map(workspace.groups, & &1.route_ids))
    Enum.reject(workspace.routes, &MapSet.member?(grouped, &1.route_id))
  end

  defp first_group_id(workspace) do
    case List.first(workspace.groups) do
      nil -> nil
      group -> group.network_id
    end
  end

  # The fare a group-wide rule — one naming no zone pair — charges this group.
  defp flat_rule_fare(group, workspace) do
    Enum.find_value(workspace.fares, fn fare ->
      if fare.kind == "single" and
           Enum.any?(fare.rules, fn rule ->
             rule.network_id == group.network_id and blank_area?(rule.from_area_id) and
               blank_area?(rule.to_area_id)
           end) do
        fare
      end
    end)
  end

  defp cell_key(from, to), do: "#{from.area_id}-#{to.area_id}"

  defp cell_aria_label(cell, from, to, workspace) do
    if cell.gap? do
      "#{from.name} to #{to.name}: no fare. Set a fare"
    else
      "#{from.name} to #{to.name}: #{cell_fare_names(cell, workspace)}, #{cell_price_text(cell, workspace)} adult. Change fare"
    end
  end

  # A cell's adult price, worked from the fare the cell names and the rider type
  # the version shows first — the same price the Prices tab leads each fare row
  # with.
  defp cell_price_text(cell, workspace) do
    rider = rider_default(workspace)
    amount = cell_amounts(cell, workspace) |> Map.get(rider && rider.rider_category_id)

    Money.format(amount, workspace.currency) || "—"
  end

  defp cell_fare_names(cell, workspace) do
    cell
    |> cell_fares(workspace)
    |> Enum.map_join(", ", & &1.name)
  end

  # The distinct fares a cell's rules name. A cell holding every rider type of
  # one fare is one fare, which is why the products are read through the fares
  # rather than counted.
  defp cell_fares(cell, workspace) do
    Enum.flat_map(cell.products, fn product_id ->
      case Enum.find(workspace.fares, &(product_id in &1.product_ids)) do
        nil -> []
        fare -> [fare]
      end
    end)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  defp cell_amounts(cell, workspace) do
    Enum.reduce(cell_fares(cell, workspace), %{}, fn fare, amounts ->
      Map.merge(amounts, fare.prices, fn _rider_id, left, right -> right || left end)
    end)
  end

  defp pass_fares(workspace) do
    workspace.fares
    |> Enum.filter(&(&1.kind == "pass"))
    |> Enum.map(fn fare ->
      %{
        key: List.first(fare.product_ids),
        name: fare.name,
        price: adult_amount_text(fare, workspace) || "—",
        accepted_network_ids: fare.accepted_network_ids
      }
    end)
  end

  defp adult_amount(fare, workspace) do
    rider = rider_default(workspace)
    rider && Map.get(fare.prices, rider.rider_category_id)
  end

  # The same amount the Prices tab leads the fare's row with, formatted for the
  # version's own currency.
  defp adult_amount_text(fare, workspace) do
    Money.format(adult_amount(fare, workspace), workspace.currency)
  end

  # The single rides a cell may be set to, keyed by the product id the writer
  # names one: the fare's own first row, which `Fares.set_zone_fare/7` reads as
  # the fare and writes every rider type of.
  defp single_fares(workspace) do
    for fare <- workspace.fares,
        fare.kind == "single",
        key = List.first(fare.product_ids),
        is_binary(key) do
      %{
        key: key,
        name: fare.name,
        price: adult_amount_text(fare, workspace) || "—"
      }
    end
  end

  defp rule_zones(workspace) do
    workspace.matrices
    |> Enum.flat_map(& &1.zones)
    |> Enum.uniq_by(& &1.area_id)
    |> Enum.sort_by(&{&1.name || "", &1.area_id})
  end

  defp weekday_choices do
    [{0, "Sun"}, {1, "Mon"}, {2, "Tue"}, {3, "Wed"}, {4, "Thu"}, {5, "Fri"}, {6, "Sat"}]
  end

  defp period_days(nil), do: "Every day"
  defp period_days(127), do: "Every day"
  defp period_days(31), do: "Weekdays"

  defp period_days(mask) do
    weekday_choices()
    |> Enum.filter(fn {day, _label} -> Bitwise.band(mask, weekday_bit(day)) != 0 end)
    |> Enum.map_join(", ", &elem(&1, 1))
    |> case do
      "" -> "Every day"
      days -> days
    end
  end

  defp weekday_bit(0), do: 64
  defp weekday_bit(day), do: :erlang.bsl(1, day - 1)

  defp period_range_text(%{start_time: start_time, end_time: end_time}, period) do
    ending =
      if period.until_end_of_day and end_time == "24:00:00",
        do: "end of service day",
        else: format_period_time(end_time)

    "#{format_period_time(start_time)}–#{ending}"
  end

  defp draft_ranges_text(draft) do
    Enum.map_join(draft.ranges, " or ", fn range ->
      ending =
        if draft.until_end_of_day? and range == List.last(draft.ranges),
          do: "end of service day",
          else: format_period_time(range.end_time)

      "#{format_period_time(range.start_time)}–#{ending}"
    end)
  end

  defp format_period_time(nil), do: "choose a time"

  defp format_period_time("24:00:00"), do: "end of service day"

  defp format_period_time(value) when is_binary(value) do
    normalized = if String.length(value) == 5, do: value <> ":00", else: value

    case Time.from_iso8601(normalized) do
      {:ok, time} -> Calendar.strftime(time, "%-I:%M %p")
      _ -> value
    end
  end

  defp rule_ids_text(rule) do
    "network_id #{rule.network_id || "(any)"} · from_area_id #{rule.from_area_id || "(any)"} · to_area_id #{rule.to_area_id || "(any)"} · fare_product_id #{rule.fare_product_id} · from_timeframe_group_id #{rule.from_timeframe_group_id || "(any)"}"
  end

  defp fare_rule_price(rule, workspace) do
    fare = Enum.find(workspace.fares, &(rule.fare_product_id in &1.product_ids))
    if fare, do: adult_amount_text(fare, workspace) || "—", else: "—"
  end

  defp rule_fare_name(%{fare_product_id: product_id}, workspace),
    do: rule_fare_name(product_id, workspace)

  defp rule_fare_name(product_id, workspace) do
    case Enum.find(workspace.fares, &(product_id in &1.product_ids)) do
      nil -> "the selected fare"
      fare -> fare.name
    end
  end

  defp rule_draft_sentence(%{fare_product_id: nil}, _workspace),
    do: "Choose a fare to see what this rule does."

  defp rule_draft_sentence(draft, workspace) do
    fare_rule_sentence(draft, workspace)
  end

  defp rule_save_label(%{overlap: :replace}, [clash | _rest], workspace),
    do: "Replace #{rule_fare_name(clash, workspace)}"

  defp rule_save_label(%{rule_id: nil}, _overlaps, _workspace), do: "Add fare rule"
  defp rule_save_label(_draft, _overlaps, _workspace), do: "Save rule"

  defp group_drawer_title(%{key: nil}), do: "Create route group"
  defp group_drawer_title(%{name: name}), do: "Edit route group · #{name}"

  defp group_error_summary_title(1), do: "Fix this problem to save"
  defp group_error_summary_title(_count), do: "Fix these problems to save"

  @doc false
  # The routes this draft takes out of another group, each with where it came
  # from — the same list `Fares.save_route_group/2` reports as `moved`. A group
  # being created moves nothing, because a route only moves out of a group that
  # already holds it.
  defp moved_routes(%{key: nil}, _workspace), do: []

  defp moved_routes(draft, workspace) do
    Enum.flat_map(workspace.groups, fn group ->
      if group.network_id == draft.key do
        []
      else
        Enum.map(
          Enum.filter(group.route_ids, &(&1 in draft.route_ids)),
          &%{
            route_id: &1,
            from_network_id: group.network_id
          }
        )
      end
    end)
  end

  # The routes this group holds that the draft no longer holds, which is what
  # leaves them in no group.
  defp leaving_routes(draft, workspace) do
    case Enum.find(workspace.groups, &(&1.network_id == draft.key)) do
      nil -> []
      group -> Enum.reject(group.route_ids, &(&1 in draft.route_ids))
    end
  end

  # The group a route is in besides the one being edited, which is what the
  # drawer's route list says under the route's name.
  # The other group a route belongs to, which the route list states for every
  # route rather than only the ones the draft has picked up: the move warning
  # below is about the draft, but "where this route is now" is the version's
  # own fact and has to be readable before anything is ticked.
  defp other_group_of(route, assigns) do
    assigns.workspace.groups
    |> Enum.find_value(fn group ->
      if group.network_id != assigns.draft.key and route.route_id in group.route_ids do
        group_name(assigns.workspace, group.network_id)
      end
    end)
  end

  @doc """
  Renders the mismatch banner for a managed version that still holds the
  `fare_attributes` its import stored while the export writes the ones derived
  from the version's own fare rows.

  `differences` is that comparison, already filtered to the fares the two sets
  price differently. "Keep older format as imported" calls
  `GtfsPlanner.Gtfs.Fares.set_older_format/2`, which is the only way the stored
  price survives an export.
  """
  attr :differences, :list, required: true
  attr :currency, :string, default: "USD"

  def fares_mismatch_banner(assigns) do
    ~H"""
    <.message
      id="fares-mismatch"
      kind="warning"
      role="status"
      title="Your imported feed describes these fares twice, and the two descriptions disagree"
    >
      <p id="fares-mismatch-detail">
        {Enum.map_join(@differences, "; ", &mismatch_sentence(&1, @currency))}. This table uses the newer
        format, which the GTFS reference says to prefer. Exports rebuild the older format from it,
        so {if length(@differences) == 1,
          do: "the price above",
          else: "those prices"} will not be exported.
      </p>
      <:action>
        <.button
          id="keep-older-format"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="keep_older_format"
        >
          Keep older format as imported
        </.button>
      </:action>
    </.message>
    """
  end

  # -- Setup text ---------------------------------------------------------------

  defp setup_structure_options do
    [
      %{
        value: "free",
        label: "Riders ride free",
        description: "No fare on any route. Trip planners show “Free”.",
        detail: "One $0.00 fare"
      },
      %{
        value: "flat",
        label: "One price for every ride",
        description: "The same fare on every route and between any stops."
      },
      %{
        value: "route",
        label: "Price depends on the route",
        description: "For example local routes and a higher intercity or express fare."
      },
      %{
        value: "zone",
        label: "Price depends on zones",
        description: "Riders pay more to travel between zones. You draw zones on a map next."
      }
    ]
  end

  defp setup_price_question("route"), do: "What does an adult pay on each group of routes?"
  defp setup_price_question(_kind), do: "What does an adult pay?"

  defp setup_price_label("zone"), do: "Adult price inside one zone"
  defp setup_price_label(_kind), do: "Adult price"

  defp setup_price_help("zone"), do: nil
  defp setup_price_help(_kind), do: "The price someone pays with cash when they board."

  defp setup_error_title(1), do: "Fix this problem to create fares"
  defp setup_error_title(_count), do: "Fix these problems to create fares"

  defp setup_version_phrase(nil), do: "this version"
  defp setup_version_phrase(name), do: "#{name} service"

  defp transfer_label(""), do: "Free transfers of the first boarding"
  defp transfer_label(minutes), do: "Free transfers within #{minutes} minutes of first boarding"

  # The live result card's own reading of the draft, so what the operator sees
  # under the questions is what `Conversion.setup/2` will be handed.
  defp setup_result(assigns) do
    ~H"""
    <div
      id="setup-result"
      aria-live="polite"
      class="rounded-card border border-subtle bg-canvas px-4 py-3"
    >
      <p class="text-[13px] text-muted">What riders will see</p>
      <p class="mt-0.5 font-display text-[26px] font-semibold leading-tight tracking-[-0.02em] tabular-nums text-strong">
        {setup_headline(assigns.setup, assigns.currency)}
      </p>
      <p class="mt-1 text-sm text-default">{setup_line(assigns.setup, assigns.currency)}</p>
      <p class="mt-2 text-sm font-bold text-strong">
        Creates {setup_creates(assigns.setup, assigns.currency)}. Nothing is saved until you
        create them.
      </p>
    </div>
    """
  end

  # A version with no fare rows has no currency of its own to read, so the card
  # states the currency `Conversion.setup/2` writes its prices in.
  defp setup_currency(_setup), do: "USD"

  defp setup_headline(%{"kind" => "free"}, _currency), do: "Free"

  defp setup_headline(%{"kind" => "route", "groups" => groups}, currency) do
    case groups |> Enum.map(&parsed_amount(&1["price"])) |> Enum.reject(&is_nil/1) do
      [] -> "Add a price"
      amounts -> Enum.map_join(amounts, " – ", &Money.format(&1, currency))
    end
  end

  defp setup_headline(setup, currency), do: setup_amount_text(setup["adult"], currency)

  defp setup_amount_text(text, currency) do
    case parsed_amount(text) do
      nil -> "Add a price"
      amount -> Money.format(amount, currency)
    end
  end

  defp setup_line(%{"kind" => "free"}, _currency),
    do: "Every ride on every route, for every rider."

  defp setup_line(setup, currency) do
    parts =
      [
        setup["reduced"] && "Reduced fare #{half_text(setup, currency)}",
        setup["child"] && "children under 6 free",
        setup["transfer"] && transfer_line(setup),
        not setup["transfer"] && "no free transfers"
      ]
      |> Enum.filter(& &1)

    Enum.join(parts, " · ")
  end

  defp transfer_line(setup) do
    "free transfers for #{setup["minutes"] || "the time limit you set"} min"
  end

  # A reduced or youth rider is half the adult price to the nearest nickel, which
  # is the rule `Conversion.setup/2` writes. Twenty halves make a dime, so the
  # nearest nickel is the nearest whole of a twentieth.
  defp half_text(setup, currency) do
    case parsed_amount(setup["adult"]) do
      nil -> "—"
      amount -> Money.format(nickel_half(amount), currency)
    end
  end

  defp nickel_half(amount) do
    amount |> Decimal.div(2) |> Decimal.mult(20) |> Decimal.round(0) |> Decimal.div(20)
  end

  defp setup_creates(%{"kind" => "free"}, _currency), do: "1 free fare"

  defp setup_creates(%{"kind" => "route"} = setup, _currency) do
    count = length(setup["groups"])

    Enum.join(
      [
        "#{count} #{if count == 1, do: "fare", else: "fares"} and #{count} route #{if count == 1, do: "group", else: "groups"}",
        rider_count_text(setup),
        setup["transfer"] && "1 transfer rule"
      ]
      |> Enum.filter(& &1),
      ", "
    )
  end

  defp setup_creates(setup, _currency) do
    Enum.join(
      [
        "1 fare",
        rider_count_text(setup),
        setup["transfer"] && "1 transfer rule"
      ]
      |> Enum.filter(& &1),
      ", "
    )
  end

  defp rider_count_text(setup) do
    count =
      1 +
        Enum.count(
          [
            setup["reduced"] && true,
            setup["youth"] && true,
            setup["child"] && true
          ],
          & &1
        )

    counted(count, "rider type", "rider types")
  end

  defp parsed_amount(text) do
    case Money.parse(to_string(text || "")) do
      {:ok, amount} -> amount
      {:error, :invalid} -> nil
    end
  end

  # -- Conversion text ----------------------------------------------------------

  @unmanaged_order [
    "fare_attributes",
    "fare_rules",
    "fare_products",
    "fare_leg_rules",
    "fare_transfer_rules",
    "fare_leg_join_rules",
    "fare_media",
    "rider_categories",
    "networks",
    "fare_time_periods",
    "fare_product_details",
    "fare_zones",
    "route_networks"
  ]

  @conversion_rows %{
    "fare_attributes" => {"fare attribute", "fare attributes"},
    "fare_rules" => {"fare rule", "fare rules"},
    "fare_products" => {"fare", "fares"},
    "fare_leg_rules" => {"leg rule", "leg rules"},
    "fare_transfer_rules" => {"transfer rule", "transfer rules"},
    "fare_leg_join_rules" => {"read-only rule", "read-only rules"},
    "fare_media" => {"payment method", "payment methods"},
    "rider_categories" => {"rider type", "rider types"},
    "networks" => {"network", "networks"},
    "route_networks" => {"route group", "route groups"},
    "fare_time_periods" => {"time period", "time periods"},
    "fare_product_details" => {"fare detail", "fare details"},
    "fare_zones" => {"fare zone", "fare zones"}
  }

  defp conversion_title(%{state: :refused}), do: "These fares can’t be edited here yet"
  defp conversion_title(_conversion), do: "Convert these fares to the newer format?"

  # The rows the conversion would create, in the order `Fares` counts them, each
  # as a sentence rather than a bare count.
  defp conversion_counts(plan) do
    plan.creates
    |> Enum.sort_by(fn {table, _count} -> table_index(table) end)
    |> Enum.reject(fn {_table, count} -> count == 0 end)
    |> Enum.map(fn {table, count} ->
      "#{counted(count, conversion_row(table), conversion_rows(table))}"
    end)
  end

  defp table_index(table), do: Enum.find_index(@unmanaged_order, &(&1 == table_key(table))) || 0

  defp conversion_row(table), do: conversion_names(table_key(table), "row")

  defp conversion_rows(table), do: conversion_names(table_key(table), "rows")

  # A conversion plan names its tables the way `Fares` counts them, as atoms.
  defp table_key(table), do: to_string(table)

  defp conversion_names(table, key) do
    case Map.fetch(@conversion_rows, table) do
      {:ok, {one, many}} -> if key == "row", do: one, else: many
      :error -> if key == "row", do: "row", else: "rows"
    end
  end

  defp transfer_allowance(%{transfers: nil}), do: "Unlimited transfers"
  defp transfer_allowance(%{transfers: 0}), do: "No free transfers"
  defp transfer_allowance(%{transfers: 1}), do: "1 free transfer"
  defp transfer_allowance(%{transfers: count}), do: "#{count} free transfers"

  defp mismatch_sentence(%{fare_id: fare_id, stored: stored, derived: derived}, currency) do
    "#{fare_id} costs #{Money.format(stored, currency)} as imported and " <>
      "#{Money.format(derived, currency)} here"
  end

  defp free_fare_product_id(workspace) do
    case List.first(workspace.fares) do
      nil -> nil
      fare -> List.first(fare.product_ids)
    end
  end

  defp changed_by(%{history: [entry | _]}) do
    actor = entry.actor_email || "Another editor"
    "#{actor} · #{history_time(entry.inserted_at)}"
  end

  defp changed_by(_workspace), do: "just now"

  # One step of a form: a numbered mark and a question, with an optional line of
  # help. The number is decoration; the question is the heading.
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

  # -- Drawer text -------------------------------------------------------------

  @doc """
  Renders the Change prices dialog: which fares to move, by how much, for whom,
  and the prices that would change.

  `change` is the LiveView's whole dialog state — the scope, whether the change
  is an amount or a percentage, the typed value, the rounding step, the checked
  rider types, whether the reduced rider stays at half, the rows
  `Fares.preview_price_change/3` returned for those choices, and any reason the
  dialog cannot be used as it stands.

  Every row of the preview names a `fare_products` row, so the fare and rider
  type it reads are the ones the grid shows for that row, and the amounts are
  formatted through `Fares.Money.format/2` (CR-3). The table is the only thing
  that scrolls, so the actions stay in view however many prices change.

  Nothing here writes. Update is disabled while the preview is empty, and the
  status line then says why — a choice that moves no price is not a save.
  """
  attr :change, :map, required: true
  attr :workspace, :map, required: true
  attr :version_name, :string, default: nil
  attr :published?, :boolean, default: true
  attr :return_focus_id, :string, default: nil
  attr :pending?, :boolean, default: false

  def price_change_dialog(assigns) do
    assigns =
      assigns
      |> assign(:rows, change_rows(assigns.change.rows, assigns.workspace))
      |> assign(:scope_options, price_scope_options(assigns.workspace))
      |> assign(:currency, assigns.workspace.currency)

    ~H"""
    <.confirm_dialog
      id="price-change-dialog"
      chrome="planner"
      size="2xl"
      open={true}
      pending={@pending?}
      title="Change prices"
      confirm_label={
        if @rows == [],
          do: "Update prices",
          else: "Update #{counted(length(@rows), "price", "prices")}"
      }
      pending_label="Updating…"
      confirm_disabled={@rows == []}
      on_confirm="apply_price_change"
      on_cancel="cancel_change_prices"
      cancel_label="Keep prices"
      return_focus_id={@return_focus_id}
    >
      <p
        id="price-change-context"
        class="flex flex-wrap items-center gap-2 text-[13px] text-muted"
      >
        <span>{version_phrase(@version_name, @published?)}</span>
        <.badge id="price-change-preview-badge" tone="warning">Preview · not saved</.badge>
      </p>

      <form id="price-change-form" phx-change="change_price_options" class="mt-4 grid gap-5">
        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            id="price-change-scope"
            name="change[scope]"
            type="select"
            label="Which fares"
            value={to_string(@change.scope)}
            options={@scope_options}
          />
          <fieldset>
            <legend class="text-sm font-semibold text-strong">Change by</legend>
            <div class="mt-1.5 flex flex-wrap items-center gap-2">
              <.input
                id="price-change-how"
                name="change[how]"
                type="select"
                aria-label="Change by amount or percent"
                value={to_string(@change.how)}
                options={[{"An amount", "amount"}, {"A percentage", "percent"}]}
                class="w-[160px]"
              />
              <.change_value_input
                :if={@change.how == :percent}
                id="price-change-percent"
                name="change[percent]"
                value={@change.percent}
                label="Percent"
                mark="%"
                side={:right}
                invalid?={@change.value_invalid?}
              />
              <.change_value_input
                :if={@change.how == :amount}
                id="price-change-amount"
                name="change[amount]"
                value={@change.amount}
                label="Amount"
                mark="$"
                side={:left}
                invalid?={@change.value_invalid?}
              />
            </div>
            <p
              :if={@change.value_invalid?}
              id="price-change-value-error"
              class="mt-1.5 text-[13px] text-error-fg"
            >
              {@change.error}
            </p>
            <p class="mt-1.5 text-[13px] text-muted">Use a minus sign to lower prices.</p>
          </fieldset>
        </div>

        <fieldset>
          <legend class="text-sm font-semibold text-strong">Rider types</legend>
          <%!-- The hidden field is the marker that the rider list arrived at all:
            an unticked checkbox is absent from a form's payload, so a dialog
            where nobody is ticked sends no `riders` key at all. --%>
          <input type="hidden" name="change[riders][]" value="" />
          <div class="mt-1 flex flex-wrap gap-x-6">
            <.fare_checkbox
              :for={rider <- @workspace.riders}
              id={"price-change-rider-#{rider.rider_category_id}"}
              name="change[riders][]"
              value={rider.rider_category_id}
              label={rider.name}
              checked={rider.rider_category_id in @change.riders}
              disabled={not rider_priced?(rider, @workspace)}
            />
          </div>
          <p class="mt-1 text-[13px] text-muted">Free prices stay free.</p>
        </fieldset>

        <div class="grid gap-x-6 sm:grid-cols-2">
          <.input
            id="price-change-round"
            name="change[round]"
            type="select"
            label="Round to"
            value={@change.round}
            options={[
              {"Nearest 5 cents", "0.05"},
              {"Nearest 25 cents", "0.25"},
              {"Don’t round", "0.01"}
            ]}
          />
          <div class="pt-6">
            <input type="hidden" name="change[half_reduced?]" value="false" />
            <.fare_checkbox
              id="price-change-half"
              name="change[half_reduced?]"
              value="true"
              label="Keep reduced fares at half the adult price"
              checked={@change.half_reduced?}
            />
          </div>
        </div>

        <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <.price_change_tile
            id="price-change-count"
            number={to_string(length(@rows))}
            label="prices change"
          />
          <.price_change_tile
            id="price-change-largest"
            number={largest_change_text(@rows, @currency)}
            label="largest increase"
          />
          <.price_change_tile
            id="price-change-fares"
            number={to_string(change_fare_count(@rows, @workspace))}
            label="fares affected"
          />
        </div>

        <div
          id="price-change-preview"
          class="max-h-[260px] overflow-auto rounded-card border border-subtle bg-white"
        >
          <table class="w-full border-collapse text-sm">
            <caption class="sr-only">
              The prices these choices change, with what each one is now.
            </caption>
            <thead class="sticky top-0">
              <tr>
                <th
                  scope="col"
                  class="border-b border-subtle bg-canvas px-3 py-2 text-left text-[13px] font-semibold text-strong"
                >
                  Fare
                </th>
                <th
                  scope="col"
                  class="border-b border-subtle bg-canvas px-3 py-2 text-left text-[13px] font-semibold text-strong"
                >
                  Rider type
                </th>
                <th
                  scope="col"
                  class="border-b border-subtle bg-canvas px-3 py-2 text-right text-[13px] font-semibold text-strong"
                >
                  Now
                </th>
                <th
                  scope="col"
                  class="border-b border-subtle bg-canvas px-3 py-2 text-right text-[13px] font-semibold text-strong"
                >
                  New
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows} id={"price-change-row-#{row.fare_product_id}"}>
                <td class="border-b border-subtle px-3 py-2 text-strong">{row.fare}</td>
                <td class="border-b border-subtle px-3 text-muted">
                  {row.rider}
                  <span :if={row.medium} class="text-[13px]">· {row.medium}</span>
                </td>
                <td class="border-b border-subtle px-3 text-right tabular-nums text-muted">
                  {row.now_text}
                </td>
                <td class="border-b border-subtle px-3 text-right font-semibold tabular-nums text-strong">
                  {row.new_text}
                </td>
              </tr>
              <tr :if={@rows == []}>
                <td colspan="4" class="px-3 py-4 text-center text-muted" id="price-change-empty">
                  No prices change with these choices.
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p id="price-change-note" class="text-[13px] text-muted">
          App prices change by the same rule. A fare change usually starts with a new service
          version, so riders see the new prices from its start date.
        </p>
      </form>

      <:status>
        <p id="price-change-status" class="mb-2 text-[13px] text-muted">
          {if @change.error,
            do: @change.error,
            else: "Nothing changes until you update. #{export_phrase(@version_name, @published?)}"}
        </p>
      </:status>
    </.confirm_dialog>
    """
  end

  @doc false
  # One tile of the dialog's summary: how many prices change, by how much at
  # most, and across how many fares.
  attr :id, :string, required: true
  attr :number, :string, required: true
  attr :label, :string, required: true

  defp price_change_tile(assigns) do
    ~H"""
    <div id={@id} class="rounded-card border border-subtle bg-white px-3 py-2">
      <p class="font-display text-[26px] font-semibold leading-tight tabular-nums text-strong">
        {@number}
      </p>
      <p class="text-[13px] text-muted">{@label}</p>
    </div>
    """
  end

  @doc false
  # The typed amount or percentage, with its mark inside the field and the text
  # it was typed as kept exactly, so a half-typed field is never reformatted
  # under the cursor.
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :mark, :string, required: true
  attr :side, :atom, values: [:left, :right], required: true
  attr :invalid?, :boolean, default: false

  defp change_value_input(assigns) do
    ~H"""
    <div class="relative w-[110px]">
      <span class={[
        "pointer-events-none absolute top-1/2 -translate-y-1/2 text-sm text-muted",
        if(@side == :left, do: "left-3", else: "right-3")
      ]}>
        {@mark}
      </span>
      <input
        type="text"
        id={@id}
        name={@name}
        value={@value}
        inputmode="decimal"
        autocomplete="off"
        aria-label={@label}
        aria-invalid={to_string(@invalid?)}
        phx-debounce="300"
        class={[
          "h-11 w-full rounded-control border bg-white text-right text-sm tabular-nums text-strong",
          "focus-visible:outline-2 focus-visible:outline-offset-[-1px] focus-visible:outline-focus",
          if(@side == :left, do: "pl-7 pr-3", else: "pl-3 pr-7"),
          if(@invalid?, do: "border-error-line", else: "border-control")
        ]}
      />
    </div>
    """
  end

  # The scope choices with the counts the version holds for each, so the
  # operator picks a scope by what it would cover.
  defp price_scope_options(workspace) do
    singles = Enum.count(workspace.fares, &(&1.kind == "single"))
    passes = Enum.count(workspace.fares, &(&1.kind == "pass"))

    [
      {"Single rides (#{singles})", "single"},
      {"Passes (#{passes})", "pass"},
      {"All fares (#{length(workspace.fares)})", "all"}
    ]
  end

  # A rider type no fare is sold to, which the dialog therefore cannot change.
  defp rider_priced?(rider, workspace) do
    Enum.any?(workspace.fares, fn fare ->
      case Map.get(fare.prices, rider.rider_category_id) do
        nil -> false
        amount -> not Decimal.equal?(amount, 0)
      end
    end)
  end

  # Each preview row with the fare, rider type and payment method the grid shows
  # for that `fare_products` row, and both amounts formatted for the version's
  # own currency.
  defp change_rows(rows, workspace) do
    Enum.map(rows, fn row ->
      fare = change_fare(row.fare_product_id, workspace)
      # The fare's own method is the row the grid leads with, so it is named in
      # the Fare column by the fare's name alone; a price on another method is
      # the grid's sub-row, and names the method it differs on.
      base? = fare && row.fare_media_id == fare.base_media_id

      %{
        fare_product_id: row.fare_product_id,
        fare: if(fare, do: fare.name, else: row.fare_product_id),
        rider: rider_name(workspace, row.rider_category_id),
        medium: if(base?, do: nil, else: medium_name(workspace, row.fare_media_id)),
        now_text: Money.format(row.now, workspace.currency) || "",
        new_text: Money.format(row.new, workspace.currency) || "",
        increase: Decimal.sub(row.new, row.now)
      }
    end)
  end

  defp change_fare(nil, _workspace), do: nil

  defp change_fare(product_id, workspace) do
    Enum.find(workspace.fares, &(product_id in &1.product_ids))
  end

  # How many of the version's fares the preview touches. It is counted by the
  # fare each row belongs to rather than by row, because one fare holds several
  # `fare_products` rows — one per rider type and payment method.
  defp change_fare_count(rows, workspace) do
    rows
    |> Enum.map(fn row ->
      case change_fare(row.fare_product_id, workspace) do
        nil -> row.fare_product_id
        fare -> fare.name
      end
    end)
    |> Enum.uniq()
    |> Enum.count()
  end

  # The largest increase the preview makes, as the tiles state it: the biggest
  # any single price rises, or an em dash when nothing rises.
  defp largest_change_text([], _currency), do: "—"

  defp largest_change_text(rows, currency) do
    rows
    |> Enum.map(& &1.increase)
    |> Enum.max()
    |> then(fn amount ->
      case Money.format(amount, currency) do
        nil -> "—"
        text -> "+#{text}"
      end
    end)
  end

  defp fare_drawer_title(%{key: nil}), do: "Create fare"
  defp fare_drawer_title(%{name: name}), do: "Edit fare · #{name}"

  defp rider_drawer_title(%{key: nil}), do: "Create rider type"
  defp rider_drawer_title(%{name: name}), do: "Edit rider type · #{name}"

  defp media_drawer_title(%{key: nil}), do: "Create payment method"
  defp media_drawer_title(%{name: name}), do: "Edit payment method · #{name}"

  defp fare_error_summary_title(1), do: "Fix this problem to save"
  defp fare_error_summary_title(_count), do: "Fix these problems to save"

  # A fare being created has no id yet, so the disclosure shows the id its name
  # will produce — which is what the writer will use.
  defp fare_id_text(%{key: nil, name: name}) when is_binary(name), do: Identifier.normalize(name)
  defp fare_id_text(%{key: id}), do: id

  defp fare_rule_sentence(rule, workspace) do
    group =
      if is_nil(rule.network_id), do: "any route", else: group_name(workspace, rule.network_id)

    condition = fare_rule_condition(rule, workspace)

    time =
      case Enum.find(
             workspace.time_periods,
             &(&1.timeframe_group_id == rule.from_timeframe_group_id)
           ) do
        nil -> "at any time"
        period -> "during #{period.name || period.timeframe_group_id}"
      end

    "Rides on #{group} #{condition} #{time} pay #{rule_fare_name(rule, workspace)}."
  end

  defp fare_rule_condition(%{from_area_id: from, to_area_id: to}, workspace) do
    cond do
      blank_area?(from) and blank_area?(to) -> "between any stops"
      from == to -> "within #{zone_name(workspace, from)}"
      true -> "from #{zone_name(workspace, from)} to #{zone_name(workspace, to)}"
    end
  end

  defp rider_default(workspace) do
    Enum.find(workspace.riders, & &1.default?) || List.first(workspace.riders)
  end

  # A starting choice of "leave blank" creates no prices at all; every other
  # choice creates one per fare the version holds.
  defp starting_price_count(%{starting: "blank"}, _fares), do: 0
  defp starting_price_count(_draft, fares), do: length(fares)

  defp result_amount(_draft, amounts, workspace) do
    case rider_default(workspace) do
      nil -> nil
      rider -> Money.format(Map.get(amounts, rider.rider_category_id), workspace.currency)
    end
  end

  defp result_others(draft, workspace) do
    default = rider_default(workspace)

    for rider <- workspace.riders,
        rider.rider_category_id != (default && default.rider_category_id),
        amount = Map.get(draft.amounts, rider.rider_category_id),
        text = Money.format(amount, workspace.currency),
        do: "#{String.downcase(rider.name)} #{text}"
  end

  # The one line that says what the older format keeps. A pass has no older-format
  # row at all, and the older format's payment method is "on board" only when the
  # fare is sold on one.
  defp older_format_line(%{kind: "pass"}, _workspace),
    do: "Not in the older format, which has no passes."

  defp older_format_line(draft, workspace) do
    name = if draft.name in [nil, ""], do: "This fare", else: draft.name
    adult = result_amount(draft, draft.amounts, workspace) || "no price"

    "Older format: #{name} #{adult} for adults, paid #{fare_paid_on_board_text(draft, workspace)}."
  end

  defp fare_paid_on_board_text(draft, workspace) do
    on_board? =
      Enum.any?(workspace.media, fn medium ->
        medium.fare_media_id in draft.media_ids and medium.fare_media_type == 0
      end)

    if on_board?, do: "on board", else: "before boarding"
  end

  # The prices a new rider type would start with on one fare, spelled the way the
  # prototype's preview spells them: the amount, or "Not sold" when the starting
  # choice leaves it blank, or "Free" when the amount is zero. The fare's own
  # price is read through the rider type the version shows first, because that is
  # the price the starting choices are a fraction of.
  defp rider_starting_text(%{starting: "blank"}, _fare, _rider), do: "Not sold ·"
  defp rider_starting_text(%{starting: "free"}, _fare, _rider), do: "Free ·"

  defp rider_starting_text(%{starting: "same"}, fare, rider),
    do: "#{adult_price(fare, rider)} ·"

  defp rider_starting_text(_draft, fare, rider),
    do: "#{half_price(fare, rider)} ·"

  defp adult_price(_fare, nil), do: "Not sold ·"

  defp adult_price(fare, rider) do
    case Map.get(fare.prices, rider.rider_category_id) do
      nil -> "Not sold ·"
      amount -> "#{Money.format(amount, "USD")} ·"
    end
  end

  # Half the adult price, rounded to the nearest 5 cents as the drawer's own
  # choice card says it will be. A fare with no adult price has no half to take.
  defp half_price(fare, rider) do
    case fare && rider && Map.get(fare.prices, rider.rider_category_id) do
      nil ->
        "Not sold ·"

      amount ->
        nickels = Decimal.round(Decimal.div(Decimal.mult(amount, "0.5"), "0.05"), 0)
        "$#{Decimal.to_string(Decimal.mult(nickels, "0.05"))} ·"
    end
  end

  @media_type_help %{
    0 => "Cash or no ticket",
    1 => "Paper ticket or pass",
    2 => "Transit card",
    3 => "Contactless bank card or phone",
    4 => "Mobile app"
  }

  defp media_type_help(%{fare_media_type: type}), do: Map.get(@media_type_help, type, "")

  defp media_type_options do
    Enum.map(@media_type_help, fn {type, description} ->
      %{
        value: to_string(type),
        label: media_type_name(type),
        description: description
      }
    end)
  end

  # The fares a deleted fare's rules could point at instead: every other single
  # ride, named with the price a trip planner shows for it, and the choice of
  # removing the rules outright.
  defp fare_replacement_options(fare, workspace) do
    choices =
      for candidate <- workspace.fares,
          candidate.kind == "single",
          candidate.name != fare.name do
        {fare_replacement_label(candidate, workspace), List.first(candidate.product_ids)}
      end

    choices ++
      [{"No fare — remove the #{counted(length(fare.rules), "rule", "rules")}", "none"}]
  end

  defp fare_replacement_label(fare, workspace) do
    rider = rider_default(workspace)

    amount =
      rider && Money.format(Map.get(fare.prices, rider.rider_category_id), workspace.currency)

    if amount, do: "#{fare.name} · #{amount}", else: fare.name
  end

  defp checks_action_path(version_id, :where), do: "/gtfs/#{version_id}/settings/fares/where"

  defp checks_action_path(version_id, :transfers),
    do: "/gtfs/#{version_id}/settings/fares/transfers"

  defp checks_action_path(version_id, :prices), do: "/gtfs/#{version_id}/settings/fares"
  defp checks_action_path(version_id, _), do: "/gtfs/#{version_id}/settings/fares/checks"

  defp check_tone_class(:error), do: "border-error text-error hover:bg-error-subtle"
  defp check_tone_class(:warning), do: "border-warning text-warning hover:bg-warning-subtle"
  defp check_tone_class(:note), do: "border-subtle text-strong hover:bg-canvas"

  defp route_label(route) do
    [route.route_short_name, route.route_long_name, route.route_id]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  defp money_text(amount, currency), do: Money.format(amount, currency) || "Unknown"

  defp counted(1, one, _many), do: "1 #{one}"
  defp counted(count, _one, many), do: "#{count} #{many}"
end
