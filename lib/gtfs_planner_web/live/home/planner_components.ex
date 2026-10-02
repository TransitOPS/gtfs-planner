defmodule GtfsPlannerWeb.Home.PlannerComponents do
  @moduledoc """
  The GTFS Planner homepage's own regions: "Needs attention" and the first-use
  panel.

  `attention_list/1` renders `GtfsPlanner.Home.Attention` items in their domain
  order — service, stopped imports, check errors — with one action each; only
  the first item's action is the page's single primary action (AC-9, CR-5).
  `first_use/1` replaces the resume and check regions for a version with no
  routes, stops or calendars (AC-12).

  Data arrives as attrs from `DashboardLive`, which reads it through
  `home_source/0`; this module never loads or writes. Copy and composition come
  from `.specs/26-homepage/references/planner-home-next-step.html` (states
  `attention` and `firstuse`), except where the reference's sample data names
  its own calendars: the item text states only facts the attention item carries.
  """
  use Phoenix.Component
  use GtfsPlannerWeb, :verified_routes

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1]

  alias GtfsPlanner.Wording

  @doc """
  Needs attention: what needs a decision before riders notice.

  The first item's action is the page's primary (`.bg-action`); later items use
  the inline text action, so the page never shows two primaries (CR-5).
  """
  attr :items, :list, required: true, doc: "`GtfsPlanner.Home.Attention` items, in domain order"
  attr :version_id, :string, required: true

  def attention_list(assigns) do
    assigns = assign(assigns, :decide_text, decide_text(length(assigns.items)))

    ~H"""
    <section
      id="attention"
      aria-labelledby="attention-title"
      class="mb-6 overflow-hidden rounded-card border border-subtle bg-white"
    >
      <div class="border-b border-subtle px-5 py-4">
        <h2
          id="attention-title"
          class="text-[17px] font-bold leading-snug tracking-[-0.01em] text-strong"
        >
          Needs attention
        </h2>
        <p class="mt-0.5 text-[13px] text-muted">{@decide_text}</p>
      </div>
      <ul class="divide-y divide-subtle">
        <li
          :for={{item, index} <- Enum.with_index(@items)}
          class="flex flex-wrap items-start gap-x-4 gap-y-3 px-5 py-4"
        >
          <span class={["grid size-9 shrink-0 place-items-center rounded-full", tile_class(item)]}>
            <.icon name={tile_icon(item)} class="size-[18px]" />
          </span>
          <div class="min-w-0 flex-1 basis-[300px]">
            <h3 class="text-[15px] font-bold leading-snug text-strong">{item_title(item)}</h3>
            <p class="mt-1 text-sm text-default">{item_detail(item)}</p>
          </div>
          <.item_action item={item} version_id={@version_id} index={index} />
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  First use: a version with no routes, stops or calendars.

  The two honest ways in are the reference's cards; the import card's link is
  the page's primary action (AC-12).
  """
  attr :version_id, :string, required: true

  def first_use(assigns) do
    ~H"""
    <section id="firstuse" aria-labelledby="firstuse-title">
      <h2
        id="firstuse-title"
        class="text-[17px] font-bold leading-snug tracking-[-0.01em] text-strong"
      >
        Start with the service riders see today
      </h2>
      <p class="mt-1 max-w-[64ch] text-sm text-muted">
        Most agencies already have a GTFS feed, from a scheduling vendor or the trip-planning apps they work with. Importing it is the fastest way to start.
      </p>
      <div class="mt-5 grid gap-4 md:grid-cols-2">
        <div class="flex flex-col rounded-card border border-subtle bg-white p-6">
          <span class="grid size-11 place-items-center rounded-control bg-soft text-cyan-700">
            <.icon name="hero-arrow-up-tray" class="size-[22px]" />
          </span>
          <h3 class="mt-4 text-base font-bold text-strong">Import your current feed</h3>
          <p class="mt-1 flex-1 text-sm text-default">
            Upload the GTFS ZIP. You get every route, stop, calendar and timetable exactly as riders see them, ready to edit. The import creates a new version and leaves this one untouched until it succeeds.
          </p>
          <a
            id="firstuse-import"
            href={~p"/gtfs/#{@version_id}/import"}
            class="mt-5 inline-flex min-h-11 items-center justify-center gap-2 self-start rounded-control bg-action px-4 py-2.5 text-sm font-[650] text-white no-underline hover:bg-action-hover"
          >
            Import feed
          </a>
        </div>
        <div class="flex flex-col rounded-card border border-subtle bg-white p-6">
          <span class="grid size-11 place-items-center rounded-control bg-soft text-cyan-700">
            <.icon name="hero-plus" class="size-[22px]" />
          </span>
          <h3 class="mt-4 text-base font-bold text-strong">Start from scratch</h3>
          <p class="mt-1 flex-1 text-sm text-default">
            No feed yet? Add your agency's name, website and time zone, then your first route and its stops. A good fit for a new service or a small network.
          </p>
          <a
            id="firstuse-agency"
            href={~p"/gtfs/#{@version_id}/settings/agencies"}
            class="mt-5 inline-flex min-h-11 items-center justify-center gap-2 self-start rounded-control border border-control bg-white px-4 py-2.5 text-sm font-[650] text-strong no-underline hover:bg-canvas"
          >
            Add agency
          </a>
        </div>
      </div>
      <p class="mt-4 text-sm text-muted">
        Either way, nothing reaches riders until you export a feed and send it to your apps.
      </p>
    </section>
    """
  end

  attr :item, :map, required: true
  attr :version_id, :string, required: true
  attr :index, :integer, required: true

  defp item_action(assigns) do
    {label, href} = action(assigns.item, assigns.version_id)
    assigns = assign(assigns, label: label, href: href)

    ~H"""
    <a
      id={"attention-action-" <> Integer.to_string(@index)}
      href={@href}
      class={if(@index == 0, do: primary_link(), else: text_link())}
    >
      {@label}
      <.icon :if={@index > 0} name="hero-chevron-right" class="size-4" />
    </a>
    """
  end

  defp action(%{kind: kind}, version_id) when kind in [:service_ends, :service_ended] do
    {"Open calendars", ~p"/gtfs/#{version_id}/calendars"}
  end

  defp action(%{kind: :stopped_import}, version_id) do
    {"Review import", ~p"/gtfs/#{version_id}/import"}
  end

  defp action(%{kind: :check_errors} = item, version_id) do
    {"View the #{Wording.count_noun(item.errors, "error")}",
     ~p"/gtfs/#{version_id}/validation/#{item.run_id}"}
  end

  defp item_title(%{kind: :service_ends} = item) do
    "Service ends #{day(item.last_date)}. No calendar runs after that date."
  end

  defp item_title(%{kind: :service_ended} = item) do
    "Service ended #{day(item.last_date)}. No calendar runs after that date."
  end

  defp item_title(%{kind: :stopped_import, version_name: nil}), do: "An import stopped partway."

  defp item_title(%{kind: :stopped_import, version_name: name}) do
    "The import of “#{name}” stopped partway."
  end

  defp item_title(%{kind: :check_errors} = item) do
    "The last check found #{Wording.count_noun(item.errors, "error")} in this version."
  end

  defp item_detail(%{kind: kind} = item) when kind in [:service_ends, :service_ended] do
    "The version's calendars #{ended_phrase(item)} and nothing follows them. " <>
      "Apps that use this feed will show no service from #{day(Date.add(item.last_date, 1))}. " <>
      "Extend the calendars or add the next ones."
  end

  defp item_detail(%{kind: :stopped_import} = item) do
    "#{import_failure(item)} Discard the stopped import, then upload the feed again."
  end

  defp item_detail(%{kind: :check_errors} = item) do
    "Found #{day(item.local_at)} when the feed was exported. Apps may reject the feed until they " <>
      "are fixed. Warnings do not block anything."
  end

  defp ended_phrase(%{kind: :service_ended} = item), do: "ended on #{day(item.last_date)}"

  defp ended_phrase(%{kind: :service_ends, days: 0}), do: "end today"
  defp ended_phrase(%{kind: :service_ends, days: 1}), do: "end tomorrow"
  defp ended_phrase(%{kind: :service_ends, days: days}), do: "end in #{days} days"

  defp import_failure(%{failed_file: nil}), do: "It stopped before it finished."

  defp import_failure(%{failed_file: file, failed_row: nil}), do: "It failed in #{file}."

  defp import_failure(%{failed_file: file, failed_row: row}) do
    "It failed in #{file} at row #{row}."
  end

  defp tile_class(%{kind: kind}) when kind in [:service_ends, :service_ended],
    do: "bg-warning-bg text-warning-fg"

  defp tile_class(_item), do: "bg-error-bg text-error-fg"

  defp tile_icon(%{kind: kind}) when kind in [:service_ends, :service_ended], do: "hero-calendar"
  defp tile_icon(%{kind: :stopped_import}), do: "hero-arrow-up-tray"
  defp tile_icon(_item), do: "hero-exclamation-triangle"

  defp decide_text(1), do: "1 thing to decide before riders notice"
  defp decide_text(count), do: "#{count} things to decide before riders notice"

  defp day(%Date{} = date), do: Calendar.strftime(date, "%b %-d")
  defp day(%NaiveDateTime{} = local), do: Calendar.strftime(local, "%b %-d")

  defp primary_link do
    "inline-flex min-h-11 items-center justify-center gap-2 rounded-control bg-action px-4 py-2.5 text-sm font-[650] text-white no-underline hover:bg-action-hover max-sm:ml-[52px]"
  end

  defp text_link do
    "inline-flex min-h-11 items-center gap-1.5 text-sm font-bold text-action no-underline hover:underline max-sm:ml-[52px]"
  end
end
