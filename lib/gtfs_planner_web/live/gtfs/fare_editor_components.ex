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

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

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
      <% {:button, id, label, variant} -> %>
        <.button id={id} class="min-h-11" variant={variant} disabled={not @ready?}>
          <.icon name="hero-plus" class="size-4" /> {label}
        </.button>
    <% end %>
    """
  end

  # The tab's own primary, named once so the label and the id cannot drift from
  # each other. `:none` is a real answer for a tab that offers no action.
  defp header_action(:prices, true, _transfers?, dirty?),
    do: {:button, "create-fare", "Create fare", if(dirty?, do: "secondary", else: "primary")}

  defp header_action(:where, true, _transfers?, _dirty?),
    do: {:button, "add-fare-rule", "Add fare rule", "primary"}

  defp header_action(:transfers, true, true, _dirty?),
    do: {:button, "add-transfer-rule", "Add transfer rule", "primary"}

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
                <div class="min-w-0 text-right">
                  <span class="block text-[13px] font-semibold leading-snug text-strong">
                    {rider.name}
                  </span>
                  <span class="block text-[12px] font-normal text-muted">
                    {if(rider.default?, do: "Shown first", else: " ")}
                  </span>
                </div>
              </th>
              <th class="w-[1%] border-b border-subtle bg-canvas px-2 py-1"></th>
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
                    <span class="block text-sm font-bold text-strong">{fare.name}</span>
                    <span class="block text-[13px] font-normal text-default">
                      {fare_where_text(fare, @workspace)}
                    </span>
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
          </div>
          <ul>
            <li
              :for={medium <- @workspace.media}
              class="flex flex-wrap items-center gap-x-4 gap-y-1 border-b border-subtle px-4 py-2 last:border-b-0 sm:px-5"
            >
              <span class="text-sm font-bold text-strong">{medium.name}</span>
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
  defp counted(1, one, _many), do: "1 #{one}"
  defp counted(count, _one, many), do: "#{count} #{many}"
end
