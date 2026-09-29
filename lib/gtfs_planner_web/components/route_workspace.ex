defmodule GtfsPlannerWeb.RouteWorkspace do
  @moduledoc """
  The context every page about one route shares, from the TransitOps application
  design system's entity header (route variant): the way back to Routes, the
  route's badge, name and mode, one identifying line, and the local tabs Details,
  Patterns and Schedules.

  A route page renders `route_header/1` at the top of its own content, so the
  route reads the same wherever the person is. The header is built from utilities
  only and needs no page scope, so a page inside the design-system scope
  (`ds-page`) and one outside it can both call it.

  Called through an explicit import in each consumer; not part of the global
  `GtfsPlannerWeb.html_helpers/0` import set.
  """
  use Phoenix.Component
  use GtfsPlannerWeb, :verified_routes

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1]
  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1]

  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlannerWeb.Components.RouteIdentity

  @doc """
  The route header: back link, badge, name, mode, identifier and local tabs.

  The name is the route's long name. When the feed gives none it reads "Route 12"
  from the short name or the route ID, so the heading is never empty. The badge
  already carries the short name, so the heading does not repeat it. An
  `Inactive` chip shows only while the route is inactive.

  ## Examples

      <.route_header
        route={@route}
        gtfs_version_id={@current_gtfs_version.id}
        active_tab={:details}
      />
  """
  attr :route, :map, required: true, doc: "the route record"
  attr :gtfs_version_id, :any, required: true, doc: "the current GTFS version ID"
  attr :active_tab, :atom, values: [:details, :patterns, :schedules], default: :details

  def route_header(assigns) do
    ~H"""
    <div id="route-workspace">
      <.back_link id="route-back" navigate={"/gtfs/#{@gtfs_version_id}/routes"}>
        Routes
      </.back_link>

      <header class="mt-1">
        <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
          <RouteIdentity.route_badge route={@route} size="large" />
          <h1
            id="route-title"
            class="min-w-0 break-words font-display text-[28px] font-semibold leading-tight tracking-[-0.025em] text-strong"
          >
            {route_title(@route)}
          </h1>
          <span
            id="route-mode"
            class="inline-flex min-h-7 items-center rounded-badge bg-white px-2 text-[13px] font-[650] text-default ring-1 ring-inset ring-subtle"
          >
            {mode_label(@route.route_type)}
          </span>
          <span
            :if={!@route.active}
            id="route-inactive"
            class="inline-flex min-h-7 items-center gap-1.5 rounded-badge bg-white px-2 text-[13px] font-[650] text-muted ring-1 ring-inset ring-subtle"
          >
            <.icon name="hero-eye-slash" class="size-3.5" /> Inactive
          </span>
        </div>
        <p id="route-identifier" class="mt-2 text-sm text-muted">
          Route ID <span class="font-mono text-default">{@route.route_id}</span>
        </p>
      </header>

      <nav id="route-tabs" aria-label="Route navigation" class="mt-5 border-b border-subtle">
        <div class="flex flex-wrap items-end gap-1">
          <.link
            id="route-tab-details"
            navigate={~p"/gtfs/#{@gtfs_version_id}/routes/#{@route.route_id}"}
            class={tab_class(@active_tab == :details)}
            aria-current={@active_tab == :details && "page"}
          >
            Details
          </.link>
          <.link
            id="route-tab-patterns"
            navigate={~p"/gtfs/#{@gtfs_version_id}/routes/#{@route.route_id}/patterns"}
            class={tab_class(@active_tab == :patterns)}
            aria-current={@active_tab == :patterns && "page"}
          >
            Patterns
          </.link>
          <.link
            id="route-tab-schedules"
            navigate={~p"/gtfs/#{@gtfs_version_id}/routes/#{@route.route_id}/schedules"}
            class={tab_class(@active_tab == :schedules)}
            aria-current={@active_tab == :schedules && "page"}
          >
            Schedules
          </.link>
        </div>
      </nav>
    </div>
    """
  end

  @doc """
  What a route is called on screen: its long name, else "Route" and its short
  name, else "Route" and its route ID.
  """
  @spec route_title(map()) :: String.t()
  def route_title(route) do
    cond do
      present?(route.route_long_name) -> route.route_long_name
      present?(route.route_short_name) -> "Route #{route.route_short_name}"
      true -> "Route #{route.route_id}"
    end
  end

  @doc """
  How a sentence names a route: "Route" and its short name, else its route ID.
  """
  @spec route_label(map()) :: String.t()
  def route_label(route) do
    if present?(route.route_short_name),
      do: "Route #{route.route_short_name}",
      else: "Route #{route.route_id}"
  end

  @doc """
  A route's mode in sentence case: "Tram or light rail", "Bus". Reads the labels
  `GtfsPlanner.Gtfs.Route.route_type_label/1` owns.
  """
  @spec mode_label(integer() | nil) :: String.t()
  def mode_label(route_type) do
    route_type
    |> Route.route_type_label()
    |> String.replace("/", " or ")
    |> String.capitalize()
  end

  defp tab_class(active?) do
    [
      "-mb-px inline-flex min-h-11 shrink-0 items-center border-b-2 px-3 text-sm no-underline",
      "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
      if(active?,
        do: "border-action font-semibold text-action",
        else: "border-transparent font-medium text-muted hover:border-subtle hover:text-strong"
      )
    ]
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
