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
  name.

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

  alias GtfsPlanner.Gtfs.Fares.Money
  alias GtfsPlanner.Gtfs.Stop

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

  def header_primary(assigns) do
    ~H"""
    <%= case header_action(@active_tab, @ready?, @transfers?, @dirty?) do %>
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
  defp header_action(:prices, true, _transfers?, dirty?),
    do:
      {:button, "create-fare", "Create fare", if(dirty?, do: "secondary", else: "primary"),
       "open_fare_drawer"}

  defp header_action(:where, true, _transfers?, _dirty?),
    do: {:button, "add-fare-rule", "Add fare rule", "primary", nil}

  defp header_action(:transfers, true, true, _dirty?),
    do: {:button, "add-transfer-rule", "Add transfer rule", "primary", nil}

  defp header_action(_active_tab, _ready?, _transfers?, _dirty?), do: :none

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
                    <span
                      :if={length(fare.media) < length(@workspace.media)}
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

      <p class="px-4 py-3 text-[13px] text-muted sm:px-5">
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

  def price_cell(assigns) do
    ~H"""
    <div
      class={["relative", lens_class(@lens?, v1_cell?(@fare, @rider, @medium_id, @carried))]}
      data-lens={lens_state(@lens?, v1_cell?(@fare, @rider, @medium_id, @carried))}
    >
      <input
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
        case Stop.slugify(name) do
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

  # -- Drawer text -------------------------------------------------------------

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
  defp fare_id_text(%{key: nil, name: name}) when is_binary(name), do: Stop.slugify(name)
  defp fare_id_text(%{key: id}), do: id

  defp fare_rule_sentence(rule, workspace) do
    "#{group_name(workspace, rule.network_id)} · #{fare_rule_condition(rule, workspace)}"
  end

  defp fare_rule_condition(%{from_area_id: from, to_area_id: to}, workspace) do
    cond do
      blank_area?(from) and blank_area?(to) -> "any stops"
      from == to -> "within #{zone_name(workspace, from)}"
      true -> "#{zone_name(workspace, from)} ↔ #{zone_name(workspace, to)}"
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

  defp counted(1, one, _many), do: "1 #{one}"
  defp counted(count, _one, many), do: "#{count} #{many}"
end
