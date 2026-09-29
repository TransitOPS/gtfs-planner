defmodule GtfsPlannerWeb.StationWorkspace do
  @moduledoc """
  The frame that pages about one station share under the TransitOps design
  system: the way back, the name, one identifying line, an actions cluster and
  the station's views as underlined tabs.

  It renders in `Layouts.app`'s `:sub_header` slot. A stop that is not a station
  passes `tabs?={false}`: it has no floorplans, reports or reachability to switch
  between, so the tab row would only lead to pages that do not apply to it.

  The header carries `station-sub-nav` and `station-tab-<view>` ids so the views
  stay reachable by the same hooks as the tab bar it replaces.

  The floorplan editor fits its workspace to the viewport under the header, so it
  passes `compact` to put the way back, the name and the identifier on one row
  instead of three.
  """
  use Phoenix.Component
  use GtfsPlannerWeb, :verified_routes

  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1]

  @tabs [
    {:details, "Details", ""},
    {:diagram, "Floorplans", "/diagram"},
    {:report, "Reports", "/report"},
    {:reachability, "Reachability", "/reachability"},
    {:evolutions, "Closures", "/evolutions"}
  ]

  @doc """
  The station header.

  `title` is the name the page is about. `stop_id` names the record for the
  identifier line and the tab links; a page with no record yet (loading, or a
  failed load) omits it and gets neither. The `:meta` slot holds the words before
  the identifier ("Station · 6 platforms, 2 entrances"). The `:actions` slot
  holds the page's controls, secondary first and the one primary last.

  ## Examples

      <StationWorkspace.station_header
        title={@stop.stop_name}
        stop_id={@stop.stop_id}
        gtfs_version_id={@current_gtfs_version.id}
        active_tab={:details}
      >
        <:meta>Station · 6 platforms</:meta>
        <:actions><.button navigate={~p"/diagram"}>Open floorplans</.button></:actions>
      </StationWorkspace.station_header>
  """
  attr :title, :string, required: true
  attr :stop_id, :string, default: nil
  attr :gtfs_version_id, :any, required: true, doc: "the current GTFS version ID"

  attr :active_tab, :atom,
    values: [:details, :diagram, :report, :reachability, :evolutions],
    default: :details

  attr :tabs?, :boolean, default: true, doc: "false for a stop that is not a station"

  attr :compact, :boolean,
    default: false,
    doc: "one row for the way back, the name and the identifier line, with a smaller name"

  attr :back, :map,
    default: nil,
    doc: "`%{label: String.t(), navigate: String.t()}`; defaults to the stops list"

  slot :meta
  slot :actions

  def station_header(assigns) do
    assigns =
      assigns
      |> assign(:back, assigns.back || default_back(assigns.gtfs_version_id))
      |> assign(:tabs, if(assigns.tabs? && assigns.stop_id, do: @tabs, else: []))

    ~H"""
    <div
      id="station-sub-nav"
      class="station-workspace-header ds-page w-full"
      data-compact={@compact || nil}
    >
      <div
        :if={@compact}
        class="flex flex-wrap items-center justify-between gap-x-6 pt-1.5"
      >
        <div class="flex min-w-0 flex-wrap items-center gap-x-3">
          <.back_link id="station-back" navigate={@back.navigate}>{@back.label}</.back_link>
          <h1 id="station-title" class="min-w-0 truncate leading-tight" title={@title}>
            {@title}
          </h1>
          <.identifier_line meta={@meta} stop_id={@stop_id} class="max-sm:hidden" />
        </div>
        <div :if={@actions != []} class="flex min-h-11 items-center">
          {render_slot(@actions)}
        </div>
      </div>
      <div :if={!@compact} class="pt-2">
        <.back_link id="station-back" navigate={@back.navigate}>{@back.label}</.back_link>
      </div>
      <div
        :if={!@compact}
        class="flex flex-wrap items-start justify-between gap-x-8 gap-y-4 pb-5 pt-1"
      >
        <div class="min-w-0">
          <h1 id="station-title" class="break-words">{@title}</h1>
          <.identifier_line meta={@meta} stop_id={@stop_id} class="mt-1.5" />
        </div>
        <div
          :if={@actions != []}
          class="flex flex-wrap items-start gap-x-3 gap-y-3 sm:flex-nowrap"
        >
          {render_slot(@actions)}
        </div>
      </div>
      <nav :if={@tabs != []} aria-label="Station views" class="-mb-px overflow-x-auto">
        <div class="flex min-w-max items-end gap-x-1">
          <.link
            :for={{tab, label, suffix} <- @tabs}
            id={"station-tab-#{tab}"}
            navigate={~p"/gtfs/#{@gtfs_version_id}/stops/#{@stop_id}" <> suffix}
            aria-current={@active_tab == tab && "page"}
            class={tab_class(@active_tab == tab)}
          >
            {label}
          </.link>
        </div>
      </nav>
    </div>
    """
  end

  attr :meta, :list, required: true
  attr :stop_id, :string, default: nil
  attr :class, :any, default: nil

  defp identifier_line(assigns) do
    ~H"""
    <p
      :if={@meta != [] or @stop_id}
      class={[@class, "flex flex-wrap items-center gap-x-2 gap-y-0.5 text-sm text-muted"]}
    >
      <span :if={@meta != []}>{render_slot(@meta)}</span>
      <span :if={@meta != [] and @stop_id} aria-hidden="true" class="max-sm:hidden">·</span>
      <span :if={@stop_id} class="max-sm:basis-full">
        ID <span class="font-mono text-[13px]">{@stop_id}</span>
      </span>
    </p>
    """
  end

  defp default_back(gtfs_version_id) do
    %{label: "Stops & stations", navigate: "/gtfs/#{gtfs_version_id}/stops"}
  end

  defp tab_class(active?) do
    [
      "inline-flex min-h-11 items-center border-b-2 px-3 text-sm font-semibold no-underline",
      "focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-focus",
      if(active?,
        do: "border-action text-action",
        else: "border-transparent text-muted hover:border-subtle hover:text-strong"
      )
    ]
  end
end
