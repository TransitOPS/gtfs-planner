defmodule GtfsPlannerWeb.Home.SharedComponents do
  @moduledoc """
  The homepage regions both products share: the page head, the resume list,
  check and share, the areas strip, the People row, a region error block and
  the loading skeletons.

  The components render data the caller owns — `GtfsPlanner.Home` results
  passed through `DashboardLive` — and never load or write. Resume rows arrive
  as a `Phoenix.LiveView.LiveStream`, so the page can reset them when the data
  changes (CR-4), and every editor link comes from
  `GtfsPlannerWeb.Home.ChangeLinks`, so an item whose entity no longer exists
  renders as text without a link (AC-16).

  Presentation uses the design-system tokens scoped to `#home-page`;
  `assets/css/app.css` adds only the page's focus outline, and no global token
  changes (INV-5).
  """
  use Phoenix.Component
  use GtfsPlannerWeb, :verified_routes

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1]

  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.Components.RouteIdentity
  alias GtfsPlannerWeb.Home.ChangeLinks
  alias GtfsPlannerWeb.ProductSurfaces

  @export_again_advice "Export again to get a file with your latest work; downloads stay available for 24 hours."

  @resume_row_grid "grid min-h-16 grid-cols-[44px_minmax(0,1fr)] items-center gap-x-4 px-5 py-3 sm:grid-cols-[44px_minmax(0,1fr)_auto]"

  # The loading rows mirror the resume list: the featured placeholder plus four
  # row placeholders. Each pair is a row's title and detail placeholder width.
  @skeleton_rows [{"w-36", "w-56"}, {"w-28", "w-48"}, {"w-40", "w-44"}, {"w-32", "w-52"}]

  @doc """
  Wraps one homepage state in the page's design-system scope.

  Every state renders inside `#home-page`, which carries the page's Figtree ink
  and the page-scoped CSS in `assets/css/app.css` (INV-5).
  """
  slot :inner_block, required: true

  def home_page(assigns) do
    ~H"""
    <div id="home-page" class="font-ds text-default">
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The page head: the scope's name and the two facts a small agency checks first.

  A state whose reference draws no lede renders the `h1` alone; the access
  states do, because the heading is the whole head there.
  """
  attr :title, :string, required: true, doc: "the page's only h1"
  attr :lede, :string, default: nil, doc: "one line of scope facts; nil renders no lede"

  def home_head(assigns) do
    ~H"""
    <header id="home-head" class="pb-6 pt-8">
      <h1
        id="home-title"
        class="font-display text-[30px] font-semibold leading-[1.08] tracking-[-0.035em] text-strong"
      >
        {@title}
      </h1>
      <p :if={@lede} id="home-lede" class="mt-2 text-[15px] text-muted">{@lede}</p>
    </header>
    """
  end

  @doc """
  Continue where you left off (or, for the team scope, what the team changed).

  `items` is the stream of rows — the caller streams every resume item except
  the featured one, so an insert or reset updates only the rows. The team
  variant appends each row's author; the own variant shows the user's own work.
  With no rows the list shows the reference's empty copy, including a version
  that has no changes at all (AC-15).
  """
  attr :items, :any, required: true, doc: "the LiveStream of `{dom_id, resume_item}` rows"
  attr :scope, :atom, required: true, values: [:own, :team]
  attr :featured, :map, default: nil, doc: "the newest item, rendered above the rows"
  attr :version_id, :string, required: true

  attr :primary?, :boolean,
    default: false,
    doc: "true when the featured item's link is the page's single primary action (CR-5)"

  def resume_list(assigns) do
    assigns =
      assign(assigns,
        title:
          if(assigns.scope == :team,
            do: "What your team changed recently",
            else: "Continue where you left off"
          ),
        subtitle:
          if(assigns.scope == :team,
            do: "Changes in this version by everyone, newest first",
            else: "Your changes in this version, newest first"
          ),
        featured_link: assigns.featured && featured_path(assigns.version_id, assigns.featured)
      )

    ~H"""
    <.resume_card title={@title} subtitle={@subtitle}>
      <div
        :if={@featured}
        id="resume-latest"
        class="flex flex-wrap items-center gap-x-4 gap-y-3 border-b border-subtle px-5 py-5"
      >
        <RouteIdentity.route_badge
          :if={@featured.route}
          route={@featured.route}
          class="h-11 min-w-11 justify-center font-display text-[22px]! font-semibold!"
        />

        <span
          :if={is_nil(@featured.route)}
          class="grid size-11 shrink-0 place-items-center rounded-control bg-soft text-cyan-700"
        >
          <.icon name={kind_icon(@featured.kind)} class="size-[22px]" />
        </span>

        <div class="min-w-0 flex-1 basis-[240px]">
          <p id="resume-latest-context" class="text-[13px] font-semibold text-muted">
            {@featured.context}
          </p>
          <h3 class="mt-0.5 font-display text-[24px] font-semibold leading-tight tracking-[-0.025em] text-strong">
            {@featured.title}
          </h3>
          <p class="mt-1 text-sm text-default">
            {@featured.detail} · {day_count(@featured.same_day_count)}
          </p>
        </div>

        <a
          :if={@featured_link}
          id="resume-open"
          href={@featured_link}
          class={[
            "inline-flex min-h-11 items-center justify-center gap-2 rounded-control px-4 py-2.5 text-sm font-[650] no-underline max-sm:ml-[60px]",
            if(@primary?,
              do: "bg-action text-white hover:bg-action-hover",
              else: "border border-control bg-white text-strong hover:bg-canvas"
            )
          ]}
        >
          {featured_label(@featured)}
        </a>
      </div>

      <ul id="resume-list" phx-update="stream" class="divide-y divide-subtle">
        <li :for={{dom_id, item} <- @items} id={dom_id}>
          <.resume_row item={item} scope={@scope} version_id={@version_id} />
        </li>
        <li id="resume-empty" class="hidden px-5 py-4 text-sm text-muted only:block">
          Anything you change appears here, so you can come back to it.
        </li>
      </ul>
    </.resume_card>
    """
  end

  @doc """
  Check and share this version: the latest feed check, the latest export and the
  changes since it.

  `check`, `export` and `since` are `GtfsPlanner.Home.check_and_share/3`'s facts.
  `product` selects the export copy when the version has no export yet, because
  the facts then carry no export type.
  """
  attr :version_id, :string, required: true
  attr :product, :atom, required: true, values: [:planner, :pathways]
  attr :check, :map, default: nil, doc: "`%{run_id, errors, warnings, at, local_at}` or nil"

  attr :export, :map,
    default: nil,
    doc: "`%{run_id, type, state, expired?, finished_at, local_finished_at}` or nil"

  attr :since, :map, default: nil, doc: "`%{changes, stations}` counted after the export"

  def check_and_share(assigns) do
    assigns = assign(assigns, :export_type, export_type(assigns.export, assigns.product))

    ~H"""
    <.share_card version_id={@version_id}>
      <div id="last-check" class="px-5 py-4">
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div>
            <h3 class="text-sm font-bold text-strong">Last check</h3>
            <p :if={@check} id="check-time" class="text-[13px] text-muted">
              {format_time(@check.local_at)}
            </p>
          </div>
          <span
            :if={@check}
            id="check-badge"
            class={[
              "inline-flex items-center gap-1.5 rounded-badge px-2 py-1 text-[13px] font-[650] leading-normal",
              check_badge_class(@check)
            ]}
          >
            <.icon name={check_icon(@check)} class="size-[15px]" />
            {check_summary(@check)}
          </span>
        </div>

        <p :if={check_note(@check)} id="check-note" class="mt-2 text-sm text-default">
          {check_note(@check)}
        </p>

        <p :if={is_nil(@check)} id="check-empty" class="mt-2 text-sm text-default">
          No check yet. Run one from the export page.
        </p>

        <a
          :if={@check}
          id="check-link"
          href={~p"/gtfs/#{@version_id}/validation/#{@check.run_id}"}
          class="mt-1 inline-flex min-h-11 items-center gap-1.5 text-sm font-bold text-action no-underline hover:underline"
        >
          {check_link_label(@check)}
          <.icon name="hero-chevron-right" class="size-4" />
        </a>
      </div>

      <div id="last-export" class="border-t border-subtle px-5 py-4">
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div>
            <h3 class="text-sm font-bold text-strong">Last export</h3>
            <p :if={@export} id="export-meta" class="text-[13px] text-muted">
              {export_meta(@export)}
            </p>
          </div>
          <span
            :if={@export}
            id="export-status"
            class={[
              "inline-flex items-center gap-1.5 rounded-badge px-2 py-1 text-[13px] font-[650] leading-normal",
              export_status_class(@export)
            ]}
          >
            {export_status(@export)}
          </span>
        </div>

        <p id="export-note" class="mt-2 text-sm text-default">
          {export_note(@export, @since, @export_type)}
        </p>

        <a
          id="export-link"
          href={~p"/gtfs/#{@version_id}/export"}
          class="mt-3 inline-flex min-h-11 items-center justify-center gap-2 rounded-control border border-control bg-white px-4 py-2.5 text-sm font-[650] text-strong no-underline hover:bg-canvas"
        >
          <.icon name="hero-arrow-down-tray" class="size-4" />
          {export_action(@export_type)}
        </a>
      </div>
    </.share_card>
    """
  end

  @doc """
  The areas strip: the menu's destinations with what you do there.

  Destinations the organization's product hides (`ProductSurfaces.visible?/2`,
  so Operations is absent for Pathways Studio) are omitted. `counts` carries the
  planner status counts keyed `:routes`, `:calendars` and `:stations`; a nil
  count renders no number.
  """
  attr :organization, :map, required: true
  attr :version_id, :string, required: true
  attr :counts, :map, default: %{}

  def areas_strip(assigns) do
    version_id = assigns.version_id

    areas =
      [
        {:routes, "Routes", "Stop patterns, timetables and transfers",
         ~p"/gtfs/#{version_id}/routes", count(assigns.counts, :routes)},
        {:calendars, "Calendars", "Which days each service runs",
         ~p"/gtfs/#{version_id}/calendars", count(assigns.counts, :calendars)},
        {:stops, "Stops & stations", "Locations, names and accessibility",
         ~p"/gtfs/#{version_id}/stops", count(assigns.counts, :stations)},
        {:operations, "Operations", "Vehicle blocks, runs and rosters",
         ~p"/gtfs/#{version_id}/blocks", nil},
        {:gtfs, "GTFS", "Export, check and import feeds", ~p"/gtfs/#{version_id}/export", nil}
      ]
      |> Enum.filter(fn {key, _label, _description, _href, _count} ->
        ProductSurfaces.visible?(assigns.organization, key)
      end)
      |> Enum.map(fn {key, label, description, href, count} ->
        %{key: key, label: label, description: description, href: href, count: count}
      end)

    assigns = assign(assigns, :areas, areas)

    ~H"""
    <nav
      id="areas"
      aria-label="Areas"
      class="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-5"
    >
      <a
        :for={area <- @areas}
        id={"area-" <> Atom.to_string(area.key)}
        href={area.href}
        class="flex min-h-11 flex-col rounded-card border border-subtle bg-white px-4 py-3.5 no-underline hover:border-control"
      >
        <span class="text-sm font-bold text-strong">
          {area.label}
          <span :if={area.count} class="font-semibold text-muted tabular-nums">· {area.count}</span>
        </span>
        <span class="mt-0.5 text-[13px] text-muted">{area.description}</span>
      </a>
    </nav>
    """
  end

  @doc """
  The People row: organization administration for the people who also edit.

  The caller renders it only for users with the admin role (AC-7).
  """
  def people_row(assigns) do
    ~H"""
    <section
      id="users-strip"
      aria-labelledby="users-strip-title"
      class="mt-6 flex flex-wrap items-center justify-between gap-x-6 gap-y-3 rounded-card border border-subtle bg-white px-5 py-3"
    >
      <div class="flex min-w-0 items-center gap-3">
        <.icon name="hero-user-group" class="size-5 shrink-0 text-muted" />
        <p class="text-sm">
          <b id="users-strip-title" class="font-bold text-strong">People</b>
          <span class="text-muted">· Invite colleagues and set who can edit</span>
        </p>
      </div>
      <a
        id="manage-users-link"
        href={~p"/admin/users"}
        class="inline-flex min-h-11 items-center gap-1.5 text-sm font-bold text-action no-underline hover:underline"
      >
        Manage users <.icon name="hero-chevron-right" class="size-4" />
      </a>
    </section>
    """
  end

  @doc """
  One failed region: what failed, what still works, and a scoped "Try again".

  The button carries `phx-value-region`, which the page's retry handler accepts
  only for known region names (CR-7).
  """
  attr :region, :string, required: true
  attr :message, :string, required: true, doc: "what failed, in the reference's bold line"
  attr :detail, :string, default: nil, doc: "what still works"

  def region_error(assigns) do
    ~H"""
    <div id={"region-error-" <> @region} class="px-5 py-6">
      <div class="flex gap-3 rounded-card bg-error-bg px-4 py-3.5 text-error-fg">
        <.icon name="hero-exclamation-triangle" class="mt-px size-5 shrink-0" />
        <div>
          <p class="text-sm font-bold">{@message}</p>
          <p :if={@detail} class="mt-0.5 text-sm">{@detail}</p>
        </div>
      </div>
      <button
        type="button"
        id={"region-error-retry-" <> @region}
        phx-click="retry"
        phx-value-region={@region}
        class="mt-4 inline-flex min-h-11 items-center justify-center gap-2 rounded-control border border-control bg-white px-4 py-2.5 text-sm font-[650] text-strong hover:bg-canvas"
      >
        <.icon name="hero-arrow-path" class="size-4" /> Try again
      </button>
    </div>
    """
  end

  @doc """
  The resume region's loading state: the card's own header plus a skeleton with
  the featured item and four rows (AC-29).
  """
  def resume_skeleton(assigns) do
    assigns = assign(assigns, :skeleton_rows, @skeleton_rows)

    ~H"""
    <.resume_card>
      <div id="resume-loading" aria-hidden="true" class="animate-pulse">
        <div class="flex items-center gap-4 border-b border-subtle px-5 py-5">
          <span class="size-11 rounded-badge bg-canvas"></span>
          <div class="flex-1">
            <div class="h-3 w-40 rounded bg-canvas"></div>
            <div class="mt-2.5 h-5 w-64 rounded bg-canvas"></div>
            <div class="mt-2 h-3 w-52 rounded bg-canvas"></div>
          </div>
          <span class="h-11 w-32 rounded-control bg-canvas"></span>
        </div>
        <div class="divide-y divide-subtle">
          <div
            :for={{title_width, detail_width} <- @skeleton_rows}
            class="flex min-h-16 items-center gap-4 px-5"
          >
            <span class="size-9 rounded-control bg-canvas"></span>
            <div class="flex-1">
              <div class={["h-3 rounded bg-canvas", title_width]}></div>
              <div class={["mt-2 h-3 rounded bg-canvas", detail_width]}></div>
            </div>
            <span class="h-3 w-24 rounded bg-canvas"></span>
          </div>
        </div>
      </div>
    </.resume_card>
    """
  end

  @doc """
  The check and share region's loading state: the card's own header and footer
  plus a skeleton with the check and export blocks (AC-29).
  """
  attr :version_id, :string, required: true

  def check_skeleton(assigns) do
    ~H"""
    <.share_card version_id={@version_id}>
      <div id="share-loading" aria-hidden="true" class="animate-pulse">
        <div class="px-5 py-4">
          <div class="h-3 w-24 rounded bg-canvas"></div>
          <div class="mt-2 h-3 w-32 rounded bg-canvas"></div>
          <div class="mt-4 h-3 w-full rounded bg-canvas"></div>
          <div class="mt-2 h-3 w-2/3 rounded bg-canvas"></div>
        </div>
        <div class="border-t border-subtle px-5 py-4">
          <div class="h-3 w-24 rounded bg-canvas"></div>
          <div class="mt-2 h-3 w-40 rounded bg-canvas"></div>
          <div class="mt-4 h-11 w-36 rounded-control bg-canvas"></div>
        </div>
      </div>
    </.share_card>
    """
  end

  @doc """
  The resume region's card shell.

  The loaded list, the loading skeleton and a failed region all render inside
  the same header, so the region's title and subtitle never change while it
  loads or fails. The defaults are the own-scope copy, which is what the
  reference draws before the scope is known.
  """
  attr :title, :string, default: "Continue where you left off"
  attr :subtitle, :string, default: "Your changes in this version, newest first"
  slot :inner_block, required: true

  def resume_card(assigns) do
    ~H"""
    <section
      id="resume"
      aria-labelledby="resume-title"
      class="overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle px-5 py-4">
        <h2
          id="resume-title"
          class="text-[17px] font-bold leading-snug tracking-[-0.01em] text-strong"
        >
          {@title}
        </h2>
        <p class="mt-0.5 text-[13px] text-muted">{@subtitle}</p>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  The check and share region's card shell.

  The loaded facts, the loading skeleton and a failed region all render inside
  the same header and the "All exports and checks" footer.
  """
  attr :version_id, :string, required: true
  slot :inner_block, required: true

  def share_card(assigns) do
    ~H"""
    <section
      id="share"
      aria-labelledby="share-title"
      class="overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle px-5 py-4">
        <h2
          id="share-title"
          class="text-[17px] font-bold leading-snug tracking-[-0.01em] text-strong"
        >
          Check and share this version
        </h2>
        <p class="mt-0.5 text-[13px] text-muted">Where the feed stands since your latest change</p>
      </div>
      {render_slot(@inner_block)}
      <div class="border-t border-subtle px-5 py-1">
        <a
          id="all-exports-link"
          href={~p"/gtfs/#{@version_id}/export"}
          class="inline-flex min-h-11 items-center gap-1.5 text-sm font-bold text-action no-underline hover:underline"
        >
          All exports and checks <.icon name="hero-chevron-right" class="size-4" />
        </a>
      </div>
    </section>
    """
  end

  attr :item, :map, required: true
  attr :scope, :atom, required: true
  attr :version_id, :string, required: true

  defp resume_row(assigns) do
    assigns =
      assign(assigns,
        path: ChangeLinks.path(assigns.version_id, assigns.item),
        meta: row_meta(assigns.item, assigns.scope),
        time: format_time(assigns.item.local_at),
        link_class: @resume_row_grid <> " no-underline hover:bg-canvas",
        grid_class: @resume_row_grid
      )

    ~H"""
    <a :if={@path} href={@path} class={@link_class}>
      <.resume_row_content item={@item} meta={@meta} time={@time} />
    </a>
    <div :if={is_nil(@path)} class={@grid_class}>
      <.resume_row_content item={@item} meta={@meta} time={@time} />
    </div>
    """
  end

  attr :item, :map, required: true
  attr :meta, :string, required: true
  attr :time, :string, required: true

  defp resume_row_content(assigns) do
    ~H"""
    <RouteIdentity.route_badge
      :if={@item.route}
      route={@item.route}
      class="row-span-2 h-[30px] min-w-[36px] justify-center px-1.5! text-sm! font-extrabold! sm:row-span-1"
    />
    <span
      :if={is_nil(@item.route)}
      class="row-span-2 grid size-9 place-items-center justify-self-center rounded-control bg-soft text-cyan-700 sm:row-span-1"
    >
      <.icon name={kind_icon(@item.kind)} class="size-[18px]" />
    </span>
    <span class="min-w-0">
      <span class="block truncate text-sm font-bold text-strong">{@item.title}</span>
      <span class="block truncate text-[13px] text-muted">{@meta}</span>
    </span>
    <span class="col-start-2 text-[13px] text-muted tabular-nums sm:col-start-auto sm:whitespace-nowrap">
      {@time}
    </span>
    """
  end

  # The row's second line: the kind label and the change, plus the author in the
  # team variant (AC-14). The featured item shows the same information as the
  # domain's context line.
  defp row_meta(item, :team), do: item_detail(item) <> " · " <> item.actor_email
  defp row_meta(item, :own), do: item_detail(item)

  defp item_detail(item) do
    case item.detail do
      detail when is_binary(detail) and detail != "" -> kind_label(item) <> " · " <> detail
      _ -> kind_label(item)
    end
  end

  # The domain's context line starts with the kind label ("Schedules · Sep 27,
  # 2:18 PM"; a station adds its level). The label never contains the
  # separator, so the first segment is the label.
  defp kind_label(%{context: context}) when is_binary(context) do
    context |> String.split(" · ", parts: 2) |> hd()
  end

  defp kind_label(_item), do: ""

  defp kind_icon(:calendar), do: "hero-calendar"
  defp kind_icon(:schedules), do: "hero-calendar"
  defp kind_icon(:station), do: "hero-map-pin"
  defp kind_icon(:stop), do: "hero-map-pin"
  defp kind_icon(:route_pattern), do: "hero-square-3-stack-3d"
  defp kind_icon(:route_patterns), do: "hero-square-3-stack-3d"
  defp kind_icon(:transfers), do: "hero-square-3-stack-3d"
  defp kind_icon(_kind), do: "hero-question-mark-circle"

  # No link for an item whose entity is gone (`ChangeLinks.path/2` returns nil),
  # so the featured item shows its text without a button (AC-16).
  defp featured_path(version_id, item), do: ChangeLinks.path(version_id, item)

  @doc """
  The label of a resume item's editor link.

  Shared by the planner page's featured item and the Pathways rail, where a
  station reads "Open floorplan" (AC-16, AC-27).
  """
  def featured_label(%{kind: :schedules}), do: "Open schedules"
  def featured_label(%{kind: :calendar}), do: "Open calendar"
  def featured_label(%{kind: :route_pattern}), do: "Open pattern"
  def featured_label(%{kind: :route_patterns}), do: "Open patterns"
  def featured_label(%{kind: :station}), do: "Open floorplan"
  def featured_label(%{kind: :stop}), do: "Open stop"
  def featured_label(%{kind: :transfers}), do: "Open transfers"
  def featured_label(_item), do: "Open"

  @doc """
  One item's change count for its local day, as the resume block writes it.
  """
  def day_count(1), do: "1 change that day"
  def day_count(count), do: "#{count} changes that day"

  @doc """
  The check's tone: the newest run's worst outcome (AC-18).

  Shared by the planner page's Check and share card and the Pathways rail.
  """
  def check_tone(%{errors: errors}) when errors > 0, do: :error
  def check_tone(%{warnings: warnings}) when warnings > 0, do: :warning
  def check_tone(_check), do: :success

  defp check_icon(check) do
    if check_tone(check) == :success, do: "hero-check-circle", else: "hero-exclamation-triangle"
  end

  @doc """
  The check's summary line: "No errors · 12 warnings" / "2 errors · 4 warnings".

  Shared by the planner page's Check and share card and the Pathways rail.
  """
  def check_summary(check) do
    "#{if(check.errors == 0, do: "No errors", else: Wording.count_noun(check.errors, "error"))} · " <>
      if(check.warnings == 0,
        do: "no warnings",
        else: Wording.count_noun(check.warnings, "warning")
      )
  end

  defp check_badge_class(check) do
    case check_tone(check) do
      :error -> "bg-error-bg text-error-fg"
      :warning -> "bg-warning-bg text-warning-fg"
      :success -> "bg-success-bg text-success-fg"
    end
  end

  defp check_note(check) do
    case check_tone(check) do
      :error -> "Fix the errors, then export again to check the fix."
      :warning -> "Warnings are worth a look but do not stop apps from using the feed."
      :success -> nil
    end
  end

  defp check_link_label(check) do
    case check_tone(check) do
      :error ->
        "View the #{if(check.errors == 0, do: "No errors", else: Wording.count_noun(check.errors, "error")) |> String.downcase()}"

      :warning ->
        "View warnings"

      :success ->
        "View the check"
    end
  end

  # Export facts (AC-19): the type names the export, the badge names the
  # download state, and the note adds the changes counted after it.
  defp export_type(%{type: type}, _product), do: type
  defp export_type(nil, :pathways), do: :pathways
  defp export_type(nil, :planner), do: :full

  defp export_meta(%{type: type, local_finished_at: nil}), do: export_type_label(type)

  defp export_meta(%{type: type, local_finished_at: at}),
    do: "#{export_type_label(type)} · #{format_time(at)}"

  defp export_type_label(:full), do: "Full GTFS"
  defp export_type_label(:pathways), do: "Pathways export"
  defp export_type_label(:operations), do: "Operations export"

  defp export_action(:full), do: "Export GTFS"
  defp export_action(:pathways), do: "Export pathways"
  defp export_action(:operations), do: "Export operations"

  defp export_status(%{expired?: true}), do: "Download expired"
  defp export_status(%{state: :ready}), do: "Download available"
  defp export_status(%{state: state}) when state in [:pending, :building], do: "Exporting…"
  defp export_status(_export), do: "Export did not finish"

  defp export_status_class(%{expired?: true}), do: "bg-canvas text-muted"
  defp export_status_class(%{state: :ready}), do: "bg-success-bg text-success-fg"

  defp export_status_class(%{state: state}) when state in [:pending, :building],
    do: "bg-soft text-cyan-700"

  defp export_status_class(_export), do: "bg-error-bg text-error-fg"

  defp export_note(nil, _since, :pathways) do
    "No pathways export yet. Export once a station is mapped; the check runs with it."
  end

  defp export_note(nil, _since, :full), do: "No Full GTFS export yet."

  defp export_note(export, since, export_type) do
    [since_sentence(since, export_type), export_advice(export)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp since_sentence(nil, _export_type), do: nil
  defp since_sentence(%{changes: 0}, _export_type), do: "No changes since then."

  defp since_sentence(%{changes: changes} = since, export_type) do
    noun = if changes == 1, do: "change", else: "changes"
    stations = if export_type == :pathways, do: stations_suffix(since.stations), else: ""
    "#{changes} #{noun} since then#{stations}."
  end

  defp stations_suffix(1), do: " across 1 station"
  defp stations_suffix(stations), do: " across #{stations} stations"

  defp export_advice(%{state: state}) when state in [:pending, :building],
    do: "The export is still running."

  defp export_advice(%{state: :ready, expired?: false}),
    do: "Downloads stay available for 24 hours."

  defp export_advice(_export), do: @export_again_advice

  defp count(counts, key) when is_map(counts) do
    case Map.get(counts, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  @doc """
  An agency-local wall-clock time as its display time.

  `GtfsPlanner.Home` localizes every time the page shows (resume items, check,
  export and board edits) with `DisplayClock`, so a view never converts a zone
  itself and never shows a stored UTC instant as if it were local.
  """
  def format_time(%NaiveDateTime{} = local), do: Calendar.strftime(local, "%b %-d, %-I:%M %p")
end
