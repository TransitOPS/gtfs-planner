defmodule GtfsPlannerWeb.Home.StationBoardComponents do
  @moduledoc """
  The Pathways station board's regions: the lede, the compact attention strip,
  the board (search, filters, table, pager and its empty states), the first-use
  panels and the right rail.

  The board is one page with URL-driven state: `stage`, `q` and `page` arrive as
  `StationBoard.params()` from `DashboardLive`'s `handle_params`, and the search
  form and filter buttons push a new URL instead of holding client state
  (AC-24). Rows arrive as a `Phoenix.LiveView.LiveStream`, so a param change
  resets the visible page (CR-4), and the whole station cell links to the
  station's stops screen (AC-21).

  Every fact comes from attrs the caller read through `GtfsPlanner.Home`; this
  module never loads or writes. Copy and composition come from
  `.specs/26-homepage/references/pathways-home-station-board.html` (states
  `ideal`, `attention`, `firstuse-nopathways`, `firstuse-nofeed`, `loading` and
  `partial`) and the rail's role variants from
  `.specs/26-homepage/references/pathways-home-next-step.html` (`newmember`,
  `editor`), except where the acceptance criteria state the copy: the strip says
  "The last check found <n> errors" (AC-28) and the zero-station lede and panel
  follow AC-26.

  Presentation uses the design-system tokens scoped to `#home-page`; no CSS is
  added (INV-5).
  """
  use Phoenix.Component
  use GtfsPlannerWeb, :verified_routes

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1]

  import GtfsPlannerWeb.Home.SharedComponents,
    only: [
      check_summary: 1,
      check_tone: 1,
      day_count: 1,
      featured_label: 1,
      region_error: 1
    ]

  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.StationBoard
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.Home.ChangeLinks

  # The board's loading rows, as the title and detail placeholder widths the
  # reference draws for its five rows, and the attention strip's two.
  @skeleton_rows [
    {"w-40", "w-24"},
    {"w-48", "w-28"},
    {"w-36", "w-24"},
    {"w-44", "w-20"},
    {"w-32", "w-24"}
  ]
  @attention_skeleton_rows ["w-64", "w-56"]

  # The rail's rows are one-track grids, not flex rows: the email in the second
  # line is a single long nowrap word, and `minmax(0, 1fr)` keeps it from
  # inflating the page's width on a phone while the truncation still shows.
  @rail_row_class "grid min-h-11 grid-cols-[minmax(0,1fr)_auto] items-center gap-3 py-1"

  @doc """
  The board's own URL for the given params, with `page` when it is not the first.

  `stage=all`, an empty `q` and page 1 are omitted, so the default page's URL is
  `/` and a filtered one is `/?stage=not_started` (AC-24).
  """
  @spec board_path(StationBoard.params(), pos_integer() | nil) :: String.t()
  def board_path(params, page \\ nil) do
    query =
      []
      |> stage_query(params.stage)
      |> query_query(params.q)
      |> page_query(page)

    case query do
      [] -> ~p"/"
      query -> ~p"/?#{query}"
    end
  end

  @doc """
  The page's one-line scope: "<n> in <version name> · <p> have pathways · <c>
  have no open issues" (AC-20).

  `counts` is the board's counts map. Before the board answers it is `nil`, so
  the lede states only the version; a version with no stations says so, one with
  no pathways says "none with pathways yet", and the third clause is omitted
  while `clean` is unavailable, which is how a failed statuses region reads.
  """
  @spec lede(String.t(), map() | nil) :: String.t()
  def lede(version_name, nil), do: version_name

  def lede(version_name, %{all: all, not_started: not_started, clean: clean}) do
    cond do
      all == 0 ->
        "#{version_name} · no stops or stations yet"

      not_started == all ->
        "#{all} in #{version_name} · none with pathways yet"

      is_nil(clean) ->
        "#{all} in #{version_name} · #{all - not_started} have pathways"

      true ->
        "#{all} in #{version_name} · #{all - not_started} have pathways · " <>
          "#{clean} have no open issues"
    end
  end

  @doc """
  Needs attention, compact: the stopped imports and the check's errors (AC-28).

  The board carries the per-station issues, so the strip shows only what the
  board cannot. Items arrive in `GtfsPlanner.Home.Attention`'s order (stopped
  imports, then the check) and every action is an inline text link: the rail's
  "Open floorplan" stays the page's single primary action (CR-5).
  """
  attr :items, :list, required: true, doc: "`GtfsPlanner.Home.Attention` items"
  attr :version_id, :string, required: true

  def attention_strip(assigns) do
    ~H"""
    <section
      id="attention"
      aria-labelledby="attention-title"
      class="mb-6 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <h2
        id="attention-title"
        class="border-b border-subtle px-5 py-3 text-sm font-bold text-strong"
      >
        Needs attention
      </h2>
      <ul class="divide-y divide-subtle">
        <li
          :for={item <- @items}
          class="flex flex-wrap items-center gap-x-4 gap-y-2 px-5 py-3"
        >
          <span class={["grid size-8 shrink-0 place-items-center rounded-full", tile_class(item)]}>
            <.icon name={tile_icon(item)} class="size-4" />
          </span>
          <p class="min-w-0 flex-1 basis-[300px] text-sm text-default">
            <b class="font-bold text-strong">{item_title(item)}</b> {item_detail(item)}
          </p>
          <a
            id={"attention-action-" <> item_key(item)}
            href={item_href(item, @version_id)}
            class="inline-flex min-h-11 items-center gap-1.5 text-sm font-bold text-action no-underline hover:underline"
          >
            {item_action(item)}
            <.icon name="hero-chevron-right" class="size-4" />
          </a>
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  The attention strip's loading state: the same card with two skeleton rows
  (AC-29).
  """
  def attention_skeleton(assigns) do
    assigns = assign(assigns, :skeleton_rows, @attention_skeleton_rows)

    ~H"""
    <section
      id="attention"
      aria-labelledby="attention-title"
      class="mb-6 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <h2
        id="attention-title"
        class="border-b border-subtle px-5 py-3 text-sm font-bold text-strong"
      >
        Needs attention
      </h2>
      <div id="attention-loading" aria-hidden="true" class="divide-y divide-subtle">
        <div :for={width <- @skeleton_rows} class="flex min-h-16 items-center gap-4 px-5">
          <span class="size-8 shrink-0 rounded-full bg-canvas"></span>
          <div class={["h-3 rounded bg-canvas", width]}></div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  The attention strip's failure state: the card shell and a scoped retry
  (AC-29).
  """
  def attention_error(assigns) do
    ~H"""
    <section
      id="attention"
      aria-labelledby="attention-title"
      class="mb-6 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <h2
        id="attention-title"
        class="border-b border-subtle px-5 py-3 text-sm font-bold text-strong"
      >
        Needs attention
      </h2>
      <.region_error
        region="attention"
        message="What needs attention could not load."
        detail="The station board below still works. Nothing you saved is affected."
      />
    </section>
    """
  end

  @doc """
  The board: every station, where it stands, who touched it last (AC-21).

  The header holds the search form and the version-total filter counts; the body
  is the semantic table whose rows come from the `:rows` stream, followed by the
  no-match empty state or the pager. `statuses_failed?` renders the reference's
  partial banner, and `no_pathways?` the first-use guidance above the table
  (AC-25, AC-26, AC-29).
  """
  attr :version_id, :string, required: true
  attr :params, :map, required: true, doc: "`StationBoard.params()`"
  attr :summary, :map, required: true, doc: "`query/3`'s page, totals and counts"
  attr :counts, :map, required: true, doc: "the version-total counts, nil-safe"
  attr :rows, :any, required: true, doc: "the `board_rows` stream"
  attr :statuses_failed?, :boolean, default: false
  attr :no_pathways?, :boolean, default: false

  def board(assigns) do
    ~H"""
    <section
      id="board"
      aria-labelledby="board-title"
      class="overflow-hidden rounded-card border border-subtle bg-white"
    >
      <.board_header params={@params} counts={@counts} />
      <.statuses_unavailable :if={@statuses_failed?} />
      <.no_pathways_guidance :if={@no_pathways?} />

      <div class="overflow-x-auto">
        <table id="board-table" class="w-full text-sm">
          <.board_columns />
          <tbody id="board-rows" phx-update="stream" class="divide-y divide-subtle">
            <tr :for={{dom_id, row} <- @rows} id={dom_id} class="hover:bg-canvas">
              <.board_row row={row} version_id={@version_id} />
            </tr>
          </tbody>
        </table>
      </div>

      <%= if @summary.total == 0 do %>
        <div class="border-t border-subtle px-5 py-8">
          <p id="board-empty" class="text-sm text-muted">
            No station matches. Clear the search or choose another filter.
          </p>
          <.link
            id="board-empty-clear"
            patch={board_path(%{stage: :all, q: ""})}
            class="inline-flex min-h-11 items-center gap-1.5 text-sm font-bold text-action no-underline hover:underline"
          >
            Clear filters
          </.link>
        </div>
      <% else %>
        <div class="flex flex-wrap items-center justify-between gap-x-6 gap-y-2 border-t border-subtle px-5 py-2">
          <p id="board-count" class="text-[13px] text-muted">
            Showing {@summary.showing} of {@summary.total} · {order_text(@params.stage)}
          </p>
          <div class="flex items-center gap-4">
            <.link
              :if={@summary.page > 1}
              id="board-prev"
              patch={board_path(@params, @summary.page - 1)}
              class="inline-flex min-h-11 items-center gap-1.5 text-sm font-bold text-action no-underline hover:underline"
            >
              <.icon name="hero-chevron-left" class="size-4" /> Previous
            </.link>
            <.link
              :if={@summary.page < @summary.total_pages}
              id="board-next"
              patch={board_path(@params, @summary.page + 1)}
              class="inline-flex min-h-11 items-center gap-1.5 text-sm font-bold text-action no-underline hover:underline"
            >
              Next 12 <.icon name="hero-chevron-right" class="size-4" />
            </.link>
          </div>
        </div>
      <% end %>
    </section>
    """
  end

  @doc """
  The board's loading state: the header with "–" counts, the table's columns and
  five skeleton rows (AC-29).
  """
  attr :params, :map, required: true

  def board_skeleton(assigns) do
    assigns = assign(assigns, :skeleton_rows, @skeleton_rows)

    ~H"""
    <section
      id="board"
      aria-labelledby="board-title"
      class="overflow-hidden rounded-card border border-subtle bg-white"
    >
      <.board_header
        params={@params}
        counts={%{all: nil, not_started: nil, in_progress: nil, clean: nil}}
      />
      <div class="overflow-x-auto">
        <table id="board-table" class="w-full text-sm">
          <.board_columns />
          <tbody id="board-loading" aria-hidden="true" class="animate-pulse divide-y divide-subtle">
            <tr :for={{title_width, detail_width} <- @skeleton_rows}>
              <td class="px-5 py-4" colspan="6">
                <div class={["h-3 rounded bg-canvas", title_width]}></div>
                <div class={["mt-2 h-3 rounded bg-canvas", detail_width]}></div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div class="border-t border-subtle px-5 py-2">
        <p id="board-count" class="text-[13px] text-muted">Loading stations…</p>
      </div>
    </section>
    """
  end

  @doc """
  The board's failure state: the card's title and a scoped retry (AC-29).
  """
  def board_error(assigns) do
    ~H"""
    <section
      id="board"
      aria-labelledby="board-title"
      class="overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle px-5 py-4">
        <h2
          id="board-title"
          class="text-[17px] font-bold leading-snug tracking-[-0.01em] text-strong"
        >
          Where each station stands
        </h2>
      </div>
      <.region_error
        region="board"
        message="The station list could not load."
        detail="Stations still open from the menu. Nothing you saved is affected."
      />
    </section>
    """
  end

  @doc """
  First use, no feed: stations come from the feed, so import comes first (AC-26).

  The panel replaces the attention strip, the board and the rail, and its
  "Import feed" is the page's only primary action.
  """
  attr :version_id, :string, required: true

  def first_use_no_feed(assigns) do
    ~H"""
    <section
      id="firstuse-nofeed"
      aria-labelledby="firstuse-nofeed-title"
      class="max-w-[760px] rounded-card border border-subtle bg-white p-6 sm:p-8"
    >
      <span class="grid size-11 place-items-center rounded-control bg-soft text-cyan-700">
        <.icon name="hero-arrow-up-tray" class="size-[22px]" />
      </span>
      <h2
        id="firstuse-nofeed-title"
        class="mt-4 text-[17px] font-bold leading-snug tracking-[-0.01em] text-strong"
      >
        Import your GTFS feed first
      </h2>
      <p class="mt-1 max-w-[60ch] text-sm text-default">
        Stations and their platforms come from the feed and fill this board. Levels, floorplans and pathways are added on top of them here. If you already have
        <code class="font-mono text-[13px]">pathways.txt</code>
        and <code class="font-mono text-[13px]">levels.txt</code>, include them in the ZIP.
      </p>
      <a
        id="firstuse-import"
        href={~p"/gtfs/#{@version_id}/import"}
        class="mt-5 inline-flex min-h-11 items-center justify-center gap-2 rounded-control bg-action px-4 py-2.5 text-sm font-[650] text-white no-underline hover:bg-action-hover"
      >
        Import feed
      </a>
    </section>
    """
  end

  @doc """
  First use, stations but no pathways: the board is the chooser (AC-26).

  The guidance sits above the table, so the table itself stays the way to pick a
  station.
  """
  def no_pathways_guidance(assigns) do
    ~H"""
    <div
      id="board-guidance"
      class="flex gap-3 border-b border-subtle bg-info-bg px-5 py-4 text-info-fg"
    >
      <.icon name="hero-information-circle" class="mt-0.5 size-5 shrink-0" />
      <div>
        <p class="text-sm font-bold">No station has pathways yet. Pick one below to start.</p>
        <p class="mt-0.5 text-sm">
          For each level, add a floorplan, place its entrances, platforms and the nodes between them, then connect them with pathways. The station's report shows what is still missing.
        </p>
      </div>
    </div>
    """
  end

  @doc """
  The rail card. Continue, Editing now and Share pathways data share it, so their
  loading and failed states keep the same heading (AC-27).
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  def rail_card(assigns) do
    ~H"""
    <section
      id={@id}
      aria-labelledby={@id <> "-title"}
      class="rounded-card border border-subtle bg-white p-5"
    >
      <h2
        id={@id <> "-title"}
        class="text-[17px] font-bold leading-snug tracking-[-0.01em] text-strong"
      >
        {@title}
      </h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Continue where you left off: the featured resume item, or the team's changes.

  The own scope's featured item is the rail's primary action — "Open floorplan"
  when it is a station (AC-27); the team scope lists everyone's destinations
  with the author, which is how the reference draws the `newmember` variant.
  Rows arrive as the `resume_rows` stream, and a version with no changes at all
  shows the reference's empty copy (AC-15).
  """
  attr :featured, :map, default: nil
  attr :scope, :atom, required: true, values: [:own, :team]
  attr :items, :any, required: true, doc: "the `resume_rows` stream"
  attr :version_id, :string, required: true

  def rail_resume(assigns) do
    assigns =
      assign(assigns,
        title:
          if(assigns.scope == :team,
            do: "What your team changed recently",
            else: "Continue where you left off"
          ),
        featured_path: assigns.featured && ChangeLinks.path(assigns.version_id, assigns.featured)
      )

    ~H"""
    <.rail_card id="resume" title={@title}>
      <%= if @featured do %>
        <p id="resume-latest-context" class="mt-3 text-[13px] font-semibold text-muted">
          {@featured.context}
        </p>
        <p class="mt-0.5 font-display text-[22px] font-semibold leading-tight tracking-[-0.025em] text-strong">
          {@featured.title}
        </p>
        <p class="mt-1 text-sm text-default">
          {@featured.detail} · {day_count(@featured.same_day_count)}
        </p>
        <a
          :if={@featured_path}
          id="resume-open"
          href={@featured_path}
          class="mt-4 inline-flex min-h-11 items-center justify-center gap-2 rounded-control bg-action px-4 py-2.5 text-sm font-[650] text-white no-underline hover:bg-action-hover"
        >
          {featured_label(@featured)}
        </a>
      <% else %>
        <ul id="resume-list" phx-update="stream" class="mt-2 divide-y divide-subtle">
          <li :for={{dom_id, item} <- @items} id={dom_id}>
            <.rail_resume_row item={item} version_id={@version_id} />
          </li>
          <li id="resume-empty" class="hidden py-4 text-sm text-muted only:block">
            Anything you change appears here, so you can come back to it.
          </li>
        </ul>
      <% end %>
    </.rail_card>
    """
  end

  @doc """
  The rail's loading states: one skeleton per card, mirroring their final layout
  (AC-29).
  """
  def rail_resume_skeleton(assigns) do
    ~H"""
    <.rail_card id="resume" title="Continue where you left off">
      <div id="resume-loading" aria-hidden="true" class="mt-3 animate-pulse">
        <div class="h-3 w-40 rounded bg-canvas"></div>
        <div class="mt-2.5 h-5 w-32 rounded bg-canvas"></div>
        <div class="mt-2 h-3 w-full rounded bg-canvas"></div>
        <div class="mt-4 h-11 w-36 rounded-control bg-canvas"></div>
      </div>
    </.rail_card>
    """
  end

  @doc "The Share pathways data card's loading state."
  def rail_share_skeleton(assigns) do
    ~H"""
    <.rail_card id="share" title="Share pathways data">
      <div id="share-loading" aria-hidden="true" class="mt-3 animate-pulse">
        <div class="h-3 w-full rounded bg-canvas"></div>
        <div class="mt-2 h-3 w-3/4 rounded bg-canvas"></div>
        <div class="mt-4 h-11 w-40 rounded-control bg-canvas"></div>
      </div>
    </.rail_card>
    """
  end

  @doc """
  Editing now: the other people with an active station editing status (AC-27).

  The caller passes only other users' statuses, and the card is hidden when the
  list is empty.
  """
  attr :editors, :list,
    required: true,
    doc: "`Home.station_editors/2` entries, without the viewer"

  attr :version_id, :string, required: true

  def rail_editing(assigns) do
    ~H"""
    <.rail_card :if={@editors != []} id="editing-now" title="Editing now">
      <ul class="mt-2 divide-y divide-subtle">
        <li
          :for={editor <- @editors}
          class="grid min-h-11 grid-cols-[minmax(0,1fr)_auto] items-center gap-3 py-1"
        >
          <a
            id={"editing-station-" <> editor.station_stop_id}
            href={ChangeLinks.station_path(@version_id, editor.station_stop_id)}
            class="inline-flex min-h-11 items-center text-sm font-semibold text-action no-underline hover:underline"
          >
            {editor.station_name || editor.station_stop_id}
          </a>
          <span class="truncate text-[13px] text-muted">
            {ChangeLinks.display_name(editor.email)} · since {DisplayClock.format_time(
              editor.started_at
            )}
          </span>
        </li>
      </ul>
    </.rail_card>
    """
  end

  @doc """
  Share pathways data: the check, the export and the changes since it (AC-27).

  The check comes from `Home.check_and_share/3`'s facts — a reachability run is
  never the check (AC-18) — and the export line reads "download expired" for a
  sweep-pending expiry (AC-19).
  """
  attr :version_id, :string, required: true
  attr :check, :map, default: nil
  attr :export, :map, default: nil
  attr :since, :map, default: nil

  def rail_share(assigns) do
    ~H"""
    <.rail_card id="share" title="Share pathways data">
      <%= if @export do %>
        <dl class="mt-3 grid gap-1.5 text-sm">
          <div :if={@check} class="flex justify-between gap-3">
            <dt class="text-muted">Last check</dt>
            <dd class={["font-semibold", check_tone_class(@check)]}>{check_summary(@check)}</dd>
          </div>
          <div class="flex justify-between gap-3">
            <dt class="text-muted">Last export</dt>
            <dd id="export-line" class="text-default">{export_line(@export)}</dd>
          </div>
          <div :if={@since} class="flex justify-between gap-3">
            <dt class="text-muted">Since then</dt>
            <dd id="since-line" class="text-default">{since_line(@since)}</dd>
          </div>
        </dl>
      <% else %>
        <p id="share-empty" class="mt-2 text-sm text-default">
          No pathways export yet. Export once a station is mapped; the check runs with it.
        </p>
      <% end %>
      <a
        id="export-link"
        href={~p"/gtfs/#{@version_id}/export"}
        class="mt-4 inline-flex min-h-11 items-center justify-center gap-2 rounded-control border border-control bg-white px-4 py-2.5 text-sm font-[650] text-strong no-underline hover:bg-canvas"
      >
        <.icon name="hero-arrow-down-tray" class="size-4" /> Export pathways
      </a>
    </.rail_card>
    """
  end

  @doc "The Share pathways data card's failure state."
  def rail_share_error(assigns) do
    ~H"""
    <.rail_card id="share" title="Share pathways data">
      <.region_error
        region="check"
        message="The check and export details could not load."
        detail="The export page still works. Nothing you saved is affected."
      />
    </.rail_card>
    """
  end

  @doc "The Continue card's failure state."
  def rail_resume_error(assigns) do
    ~H"""
    <.rail_card id="resume" title="Continue where you left off">
      <.region_error
        region="resume"
        message="Your recent changes could not load."
        detail="Stations still open from the menu. Nothing you saved is affected."
      />
    </.rail_card>
    """
  end

  @doc """
  The board's degraded statuses banner: report and reachability are unavailable
  while the stations, levels and pathways stay current (AC-29).

  The retried region is `statuses`, which reloads only the statuses read.
  """
  def statuses_unavailable(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-subtle bg-warning-bg px-5 py-3 text-warning-fg">
      <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
      <p class="min-w-0 flex-1 basis-[280px] text-sm">
        <b class="font-bold">Report and reachability status could not load.</b>
        Stations, levels and pathways are current.
      </p>
      <button
        type="button"
        id="region-error-retry-statuses"
        phx-click="retry"
        phx-value-region="statuses"
        class="inline-flex min-h-11 items-center justify-center gap-2 rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas"
      >
        <.icon name="hero-arrow-path" class="size-4" /> Try again
      </button>
    </div>
    """
  end

  attr :params, :map, required: true
  attr :counts, :map, required: true

  defp board_header(assigns) do
    ~H"""
    <div class="border-b border-subtle px-5 py-4">
      <div class="flex flex-wrap items-center justify-between gap-x-6 gap-y-3">
        <h2
          id="board-title"
          class="text-[17px] font-bold leading-snug tracking-[-0.01em] text-strong"
        >
          Where each station stands
        </h2>
        <.search_form q={@params.q} />
      </div>
      <.filters stage={@params.stage} counts={@counts} />
    </div>
    """
  end

  # The search is a URL param like the filters, so the form patches `/` instead
  # of holding client state; the 300 ms debounce keeps one patch per pause
  # (AC-24). The label is visible because the search is the page's only filter
  # with a free-text input.
  attr :q, :string, required: true

  defp search_form(assigns) do
    assigns = assign(assigns, :form, to_form(%{"q" => assigns.q}, as: :board))

    ~H"""
    <.form
      for={@form}
      id="board-search-form"
      phx-change="search"
      phx-submit="search"
      class="flex items-center gap-2"
    >
      <label for="board-search" class="text-sm font-semibold text-strong">Search</label>
      <input
        type="search"
        id="board-search"
        name={@form[:q].name}
        value={@form[:q].value}
        phx-debounce="300"
        placeholder="Station name or ID"
        class="h-11 w-[220px] rounded-control border border-control bg-white px-3 text-sm text-strong placeholder:text-muted"
      />
    </.form>
    """
  end

  # The chips are buttons because they toggle a view state, and their counts are
  # version totals (AC-24); a missing count reads "–", which is how both the
  # loading state and an unavailable statuses region draw them (AC-29).
  attr :stage, :atom, required: true
  attr :counts, :map, required: true

  defp filters(assigns) do
    assigns = assign(assigns, :chips, chips(assigns.stage, assigns.counts))

    ~H"""
    <div id="board-filters" class="mt-3 flex flex-wrap gap-2" role="group" aria-label="Show stations">
      <button
        :for={chip <- @chips}
        type="button"
        id={"board-filter-" <> chip.key}
        phx-click="filter"
        phx-value-stage={chip.key}
        aria-pressed={to_string(chip.selected?)}
        class={chip_class(chip.selected?)}
      >
        {chip.label}
        <span class="tabular-nums">{chip.count || "–"}</span>
      </button>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :version_id, :string, required: true

  defp board_row(assigns) do
    {report, report_class} = report_cell(assigns.row)
    {reachability, reachability_class} = reachability_cell(assigns.row)

    assigns =
      assign(assigns,
        name: assigns.row.base.name || assigns.row.base.stop_id,
        subtext: row_subtext(assigns.row),
        floorplans:
          if(assigns.row.base.floorplan_count == 0,
            do: "no floorplan",
            else: Wording.count_noun(assigns.row.base.floorplan_count, "floorplan")
          ),
        report: report,
        report_class: report_class,
        reachability: reachability,
        reachability_class: reachability_class
      )

    ~H"""
    <td class="px-5 py-1.5">
      <a
        href={ChangeLinks.station_path(@version_id, @row.base.stop_id)}
        class="flex min-h-11 flex-col justify-center no-underline"
      >
        <span class="font-bold text-action hover:underline">{@name}</span>
        <span class="text-[13px] text-muted">{@subtext}</span>
      </a>
    </td>
    <td class="px-3 py-1.5 text-default max-sm:hidden">
      {@row.base.level_count} <span class="text-muted">· {@floorplans}</span>
    </td>
    <td class={[
      "px-3 py-1.5 text-right tabular-nums",
      @row.base.pathway_count == 0 && "text-muted"
    ]}>
      {@row.base.pathway_count}
    </td>
    <td class="px-3 py-1.5">
      <span class={@report_class}>{@report}</span>
    </td>
    <td class="px-3 py-1.5">
      <span class={@reachability_class}>{@reachability}</span>
    </td>
    <td class="px-5 py-1.5 max-sm:hidden">
      <%= if @row.base.last_edited_local do %>
        <span class="block text-default">
          {DisplayClock.format_datetime(@row.base.last_edited_local)}
        </span>
        <span class="block truncate text-[13px] text-muted">{@row.base.last_edited_by}</span>
      <% else %>
        <span class="text-muted">—</span>
      <% end %>
    </td>
    """
  end

  attr :item, :map, required: true
  attr :version_id, :string, required: true

  defp rail_resume_row(assigns) do
    assigns =
      assign(assigns,
        path: ChangeLinks.path(assigns.version_id, assigns.item),
        row_class: @rail_row_class <> " no-underline"
      )

    ~H"""
    <a
      :if={@path}
      href={@path}
      class={@row_class}
    >
      <.rail_resume_row_content item={@item} />
    </a>
    <div :if={is_nil(@path)} class={@row_class}>
      <.rail_resume_row_content item={@item} />
    </div>
    """
  end

  attr :item, :map, required: true

  defp rail_resume_row_content(assigns) do
    ~H"""
    <span class="min-w-0">
      <span class="block truncate text-sm font-bold text-strong hover:underline">{@item.title}</span>
      <span class="block truncate text-[13px] text-muted">
        {@item.detail} · {@item.actor_email}
      </span>
    </span>
    <span class="shrink-0 text-[13px] text-muted tabular-nums">
      {DisplayClock.format_datetime(@item.local_at)}
    </span>
    """
  end

  defp board_columns(assigns) do
    ~H"""
    <thead>
      <tr class="border-b border-subtle text-left text-[13px] text-muted">
        <th scope="col" class="px-5 py-2.5 font-semibold">Station</th>
        <th scope="col" class="px-3 py-2.5 font-semibold max-sm:hidden">Levels</th>
        <th scope="col" class="px-3 py-2.5 text-right font-semibold">Pathways</th>
        <th scope="col" class="px-3 py-2.5 font-semibold">Report</th>
        <th scope="col" class="px-3 py-2.5 font-semibold">Reachability</th>
        <th scope="col" class="px-5 py-2.5 font-semibold max-sm:hidden">Last edited</th>
      </tr>
    </thead>
    """
  end

  defp chips(stage, counts) do
    [
      {:all, "All"},
      {:not_started, "Not started"},
      {:in_progress, "In progress"},
      {:clean, "No open issues"}
    ]
    |> Enum.map(fn {key, label} ->
      %{
        key: Atom.to_string(key),
        label: label,
        selected?: key == stage,
        count: count(counts, key)
      }
    end)
  end

  defp count(nil, _key), do: nil

  defp count(counts, key) do
    case Map.get(counts, key) do
      value when is_integer(value) -> value
      _missing -> nil
    end
  end

  defp chip_class(true),
    do:
      "inline-flex min-h-11 items-center gap-1.5 rounded-control border border-action bg-selection px-3 text-sm font-semibold text-action"

  defp chip_class(false),
    do:
      "inline-flex min-h-11 items-center gap-1.5 rounded-control border border-control bg-white px-3 text-sm font-semibold text-strong hover:bg-canvas"

  # The station cell's second line: the id, its line count through the station's
  # platforms, and the editing marker (AC-21).
  defp row_subtext(row) do
    lines = Wording.count_noun(row.lines, "line")

    if row.editing? do
      "#{row.base.stop_id} · #{lines} · editing now"
    else
      "#{row.base.stop_id} · #{lines}"
    end
  end

  # A station without pathways is "Not started" whatever its status; a station
  # with pathways whose statuses are unavailable is "Unavailable" (AC-21, AC-29).
  defp report_cell(%{stage: :not_started}), do: {"Not started", "font-normal text-muted"}
  defp report_cell(%{stage: :unknown}), do: {"Unavailable", "font-normal text-muted"}
  defp report_cell(%{status: %{issues: 0}}), do: {"No issues", "font-semibold text-success-fg"}
  defp report_cell(%{status: %{issues: 1}}), do: {"1 issue", "font-semibold text-warning-fg"}

  defp report_cell(%{status: %{issues: issues}}),
    do: {"#{issues} issues", "font-semibold text-warning-fg"}

  defp reachability_cell(%{stage: :not_started}), do: {"Not run", "font-normal text-muted"}
  defp reachability_cell(%{stage: :unknown}), do: {"Unavailable", "font-normal text-muted"}

  defp reachability_cell(%{status: %{reachability: nil}}),
    do: {"Not run", "font-normal text-muted"}

  defp reachability_cell(%{status: %{reachability: %{stale?: true}}}),
    do: {"Edited since run", "font-semibold text-muted"}

  defp reachability_cell(%{status: %{reachability: reachability}}) do
    {"#{reachability.reachable} of #{reachability.pair_count} pass",
     outcome_tone(reachability.outcome)}
  end

  defp outcome_tone(:passed), do: "font-semibold text-success-fg"
  defp outcome_tone(:warning), do: "font-semibold text-warning-fg"
  defp outcome_tone(:failed), do: "font-semibold text-error-fg"
  defp outcome_tone(:not_applicable), do: "font-normal text-muted"

  defp order_text(:not_started), do: "by name"
  defp order_text(_stage), do: "most recently edited first, then by name"

  defp item_key(%{kind: :check_errors}), do: "check"
  defp item_key(%{kind: :stopped_import}), do: "import"

  defp tile_class(_item), do: "bg-error-bg text-error-fg"

  defp tile_icon(%{kind: :check_errors}), do: "hero-exclamation-triangle"
  defp tile_icon(_item), do: "hero-arrow-up-tray"

  defp item_title(%{kind: :check_errors} = item) do
    "The last check found #{Wording.count_noun(item.errors, "error")}."
  end

  defp item_title(%{kind: :stopped_import, version_name: nil}), do: "An import stopped partway."

  defp item_title(%{kind: :stopped_import, version_name: name}) do
    "The import of “#{name}” stopped partway."
  end

  defp item_detail(%{kind: :check_errors} = item) do
    "Found #{Wording.short_date(item.local_at)}. Apps may reject the pathways files until they are fixed. " <>
      "Warnings do not block anything."
  end

  defp item_detail(%{kind: :stopped_import}) do
    "This feed and its pathways are unchanged. Discard it, then upload again."
  end

  defp item_action(%{kind: :check_errors} = item) do
    "View the #{Wording.count_noun(item.errors, "error")}"
  end

  defp item_action(%{kind: :stopped_import}), do: "Review import"

  defp item_href(%{kind: :check_errors} = item, version_id) do
    ~p"/gtfs/#{version_id}/validation/#{item.run_id}"
  end

  defp item_href(%{kind: :stopped_import}, version_id), do: ~p"/gtfs/#{version_id}/import"

  # The rail's export line: the run's local day and its download state (AC-19).
  defp export_line(%{expired?: true}), do: "download expired"
  defp export_line(%{local_finished_at: nil, state: state}), do: export_state(state)

  defp export_line(%{local_finished_at: at, state: state}),
    do: "#{Wording.short_date(at)} · #{export_state(state)}"

  defp export_state(:ready), do: "download available"
  defp export_state(state) when state in [:pending, :building], do: "exporting…"
  defp export_state(_state), do: "export did not finish"

  defp since_line(%{changes: 0}), do: "No changes since then"

  defp since_line(%{changes: changes, stations: stations}),
    do: "#{Wording.count_noun(changes, "change")}, #{Wording.count_noun(stations, "station")}"

  defp check_tone_class(check) do
    case check_tone(check) do
      :error -> "text-error-fg"
      :warning -> "text-warning-fg"
      :success -> "text-success-fg"
    end
  end

  defp stage_query(query, :all), do: query
  defp stage_query(query, stage), do: query ++ [stage: Atom.to_string(stage)]

  defp query_query(query, ""), do: query
  defp query_query(query, q), do: query ++ [q: q]

  defp page_query(query, nil), do: query
  defp page_query(query, 1), do: query
  defp page_query(query, page), do: query ++ [page: page]
end
