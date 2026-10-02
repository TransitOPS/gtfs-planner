defmodule GtfsPlannerWeb.RouteWorkspace do
  @moduledoc """
  The context every page about one route shares, from the TransitOps application
  design system's entity header (route variant): the way back to Routes, the
  route's badge, name and mode, one identifying line, and the local tabs Details,
  Patterns and Schedules.

  A route page renders `route_header/1` at the top of its own content, so the
  route reads the same wherever the person is. A page that loads its route after
  the first paint passes `route={nil}`: the header then shows only the way back,
  or a skeleton while `loading`. The header is built from utilities
  only and needs no page scope, so a page inside the design-system scope
  (`ds-page`) and one outside it can both call it.

  `crumbs/1` is the lighter context for a page that sits below the route, such as
  the pattern editor: the location trail above the page's own title. `badge/1` is
  the design system's text badge for a short status or category.

  Called through an explicit import in each consumer; not part of the global
  `GtfsPlannerWeb.html_helpers/0` import set.
  """
  use Phoenix.Component
  use GtfsPlannerWeb, :verified_routes

  import GtfsPlannerWeb.CoreComponents, only: [button: 1, icon: 1]
  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1, message: 1]

  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Values
  alias GtfsPlannerWeb.Components.RouteIdentity

  @badge_tones %{
    "neutral" => "bg-canvas text-muted",
    "success" => "bg-success-bg text-success-fg",
    "warning" => "bg-warning-bg text-warning-fg",
    "error" => "bg-error-bg text-error-fg",
    "info" => "bg-info-bg text-info-fg",
    "selected" => "bg-selection text-action"
  }

  @doc """
  The route header: back link, badge, name, mode, identifier and local tabs.

  The name is the route's long name. When the feed gives none it reads "Route 12"
  from the short name or the route ID, so the heading is never empty. The badge
  already carries the short name, so the heading does not repeat it. An
  `Inactive` chip and the message that says what inactive means for exports show
  only while the route's `active` flag is explicitly false; a route with no flag
  is eligible like an active one. A page that knows how many patterns the route
  has passes `pattern_count` to show it on the Patterns tab.

  An editing page adds what it knows about its draft: `identifier` replaces the
  identifying line, `preview` marks the header as showing unsaved values,
  `dirty` puts the "Unsaved" chip on the Details tab and `focus_title` makes
  the heading a landing place after a redirect. `trip_count` lets the inactive
  message name the trips an export leaves out. The message's Reactivate sends
  `reactivate_route` to the page.

  ## Examples

      <.route_header
        route={@route}
        gtfs_version_id={@current_gtfs_version.id}
        active_tab={:details}
      />
  """
  attr :route, :map, default: nil, doc: "the route record; nil before it has loaded"
  attr :gtfs_version_id, :any, required: true, doc: "the current GTFS version ID"
  attr :active_tab, :atom, values: [:details, :patterns, :schedules], default: :details
  attr :pattern_count, :integer, default: nil, doc: "shown on the Patterns tab when known"
  attr :loading, :boolean, default: false, doc: "draws a skeleton while the route is nil"
  attr :identifier, :string, default: nil, doc: "replaces the \"Route ID\" line"
  attr :preview, :boolean, default: false, doc: "the header shows values that are not saved"
  attr :dirty, :boolean, default: false, doc: "the page holds unsaved changes"
  attr :focus_title, :boolean, default: false, doc: "lets a redirect move focus to the heading"
  attr :trip_count, :integer, default: nil, doc: "trips an export leaves out while inactive"

  def route_header(assigns) do
    assigns = assign(assigns, :inactive?, match?(%{active: false}, assigns.route))

    ~H"""
    <div id="route-workspace">
      <.back_link id="route-back" navigate={"/gtfs/#{@gtfs_version_id}/routes"}>
        Routes
      </.back_link>

      <div :if={@route == nil and @loading} id="route-workspace-loading" aria-hidden="true">
        <div class="mt-1 flex items-center gap-4">
          <span class="h-11 w-[52px] rounded-badge bg-canvas"></span>
          <span class="h-9 w-64 rounded-badge bg-canvas"></span>
        </div>
        <span class="mt-3 block h-4 w-56 rounded-badge bg-canvas"></span>
        <div class="mt-5 flex min-h-11 items-center gap-8 border-b border-subtle">
          <span class="h-4 w-14 rounded-badge bg-canvas"></span>
          <span class="h-4 w-20 rounded-badge bg-canvas"></span>
          <span class="h-4 w-20 rounded-badge bg-canvas"></span>
        </div>
      </div>

      <header :if={@route} class="mt-1">
        <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
          <span id="route-badge" class="inline-flex">
            <RouteIdentity.route_badge route={@route} size="large" />
          </span>
          <h1
            id="route-title"
            tabindex={@focus_title && "-1"}
            class={[
              "min-w-0 break-words font-display text-[28px] font-semibold leading-tight tracking-[-0.025em] text-strong",
              @focus_title && "outline-none"
            ]}
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
            :if={@inactive?}
            id="route-inactive"
            class="inline-flex min-h-7 items-center gap-1.5 rounded-badge bg-white px-2 text-[13px] font-[650] text-muted ring-1 ring-inset ring-subtle"
          >
            <.icon name="hero-eye-slash" class="size-3.5" /> Inactive
          </span>
          <.badge :if={@preview} id="route-unsaved-preview" tone="warning" icon="hero-pencil-square">
            Unsaved preview
          </.badge>
        </div>
        <p id="route-identifier" class="mt-2 text-sm text-muted">
          <%= if @identifier do %>
            {@identifier}
          <% else %>
            Route ID <span class="font-mono text-default">{@route.route_id}</span>
          <% end %>
        </p>
      </header>

      <nav
        :if={@route}
        id="route-tabs"
        aria-label="Route navigation"
        class="mt-5 border-b border-subtle"
      >
        <div class="flex flex-wrap items-end gap-1">
          <.link
            id="route-tab-details"
            navigate={~p"/gtfs/#{@gtfs_version_id}/routes/#{@route.route_id}"}
            class={tab_class(@active_tab == :details)}
            aria-current={@active_tab == :details && "page"}
          >
            Details
            <.badge :if={@dirty} id="route-tab-details-unsaved" tone="warning" class="ml-2">
              Unsaved
            </.badge>
          </.link>
          <.link
            id="route-tab-patterns"
            navigate={~p"/gtfs/#{@gtfs_version_id}/routes/#{@route.route_id}/patterns"}
            class={[tab_class(@active_tab == :patterns), @pattern_count && "gap-2"]}
            aria-current={@active_tab == :patterns && "page"}
          >
            Patterns
            <span
              :if={@pattern_count}
              id="route-tab-patterns-count"
              class="inline-flex min-w-5 items-center justify-center rounded-badge bg-canvas px-1.5 text-[13px] font-bold tabular-nums text-default"
            >
              {@pattern_count}
            </span>
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

      <.message
        :if={@route && @inactive?}
        id="route-inactive-banner"
        kind="neutral"
        icon="hero-eye-slash"
        title={"#{route_label(@route)} is inactive."}
        class="mt-5"
      >
        {inactive_sentence(@route, @trip_count)}
        <:action>
          <.button
            id="route-reactivate"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="reactivate_route"
          >
            Reactivate route
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  defp inactive_sentence(_route, nil),
    do: "The next export leaves it out. Exports you already ran keep the route."

  defp inactive_sentence(_route, 0),
    do: "The next export leaves it out. Exports you already ran keep the route."

  defp inactive_sentence(_route, 1),
    do: "The next export leaves it out with its 1 trip. Exports you already ran keep the route."

  defp inactive_sentence(_route, count),
    do:
      "The next export leaves it out with its #{count} trips. Exports you already ran keep the route."

  @doc """
  What a route is called on screen: its long name, else "Route" and its short
  name, else "Route" and its route ID.
  """
  @spec route_title(map()) :: String.t()
  def route_title(route) do
    cond do
      Values.present?(route.route_long_name) -> route.route_long_name
      Values.present?(route.route_short_name) -> "Route #{route.route_short_name}"
      true -> "Route #{route.route_id}"
    end
  end

  @doc """
  How a sentence names a route: "Route" and its short name, else its route ID.
  """
  @spec route_label(map()) :: String.t()
  def route_label(route) do
    if Values.present?(route.route_short_name),
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

  @doc """
  A short status or category in words, on a tinted ground.

  Every badge says its meaning in text; the tone and the optional icon only
  reinforce it, so the state reads without colour.

  ## Examples

      <.badge tone="success" icon="hero-check-circle">Saved in this version</.badge>
      <.badge tone="warning">Unsaved</.badge>
  """
  attr :tone, :string, values: ~w(neutral success warning error info selected), default: "neutral"
  attr :icon, :string, default: nil, doc: "a hero icon name shown before the text"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    assigns = assign(assigns, :tone_class, Map.fetch!(@badge_tones, assigns.tone))

    ~H"""
    <span
      class={[
        "inline-flex max-w-full items-center gap-1.5 rounded-badge px-2 py-0.5 text-[13px] font-[650] leading-normal",
        @tone_class,
        @class
      ]}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} class="size-3.5 shrink-0" />{render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  The trail above a route page's title: Routes, this route with its badge, the
  section (Patterns), and the page itself.

  The section crumb is a link unless the page passes its own in the `:section`
  slot, as the pattern editor does so leaving with unsaved edits asks first. The
  current page is text, not a link, and is hidden below `md` where the trail
  would wrap.

  ## Examples

      <.crumbs route={@route} gtfs_version_id={@current_gtfs_version.id} current="New pattern" />
  """
  attr :route, :map, required: true, doc: "the route record"
  attr :gtfs_version_id, :any, required: true
  attr :current, :string, required: true, doc: "the name of the page"
  attr :id, :string, default: "route-crumbs"
  slot :section, doc: "replaces the Patterns link"

  def crumbs(assigns) do
    assigns = assign(assigns, :route_name, route_name(assigns.route))

    ~H"""
    <nav
      id={@id}
      aria-label="Location"
      class="flex flex-wrap items-center gap-x-2 text-[13px] text-muted"
    >
      <.link
        navigate={"/gtfs/#{@gtfs_version_id}/routes"}
        class="inline-flex min-h-11 items-center text-muted hover:text-strong hover:underline"
      >
        Routes
      </.link>
      <span aria-hidden="true">/</span>
      <.link
        navigate={"/gtfs/#{@gtfs_version_id}/routes/#{@route.route_id}"}
        class="inline-flex min-h-11 items-center gap-2 text-muted hover:text-strong hover:underline"
      >
        <RouteIdentity.route_badge route={@route} />{@route_name}
      </.link>
      <span aria-hidden="true">/</span>
      <%= if @section != [] do %>
        {render_slot(@section)}
      <% else %>
        <.link
          navigate={"/gtfs/#{@gtfs_version_id}/routes/#{@route.route_id}/patterns"}
          class="inline-flex min-h-11 items-center text-muted hover:text-strong hover:underline"
        >
          Patterns
        </.link>
      <% end %>
      <span aria-hidden="true">/</span>
      <span aria-current="page" class="max-w-[46ch] truncate font-semibold text-strong max-md:hidden">
        {@current}
      </span>
    </nav>
    """
  end

  # The badge already carries the short name, so the crumb leads with the long
  # name and falls back through the same fields the old route header used.
  defp route_name(route) do
    [route.route_long_name, route.route_short_name, route.route_id]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
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
end
