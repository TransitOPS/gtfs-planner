defmodule GtfsPlannerWeb.Gtfs.RouteDetailLive do
  @moduledoc """
  Route › Details: the route's saved values, editable in the shared route form
  controls, beside the reserved map column.

  The whole workspace comes from one operational read, `Gtfs.load_route_editor/3`
  through the configured catalog read adapter (default
  `GtfsPlanner.Gtfs.CatalogReadAdapter.Repo`): the route, its trusted source, the
  version's agency options and mode counts, and the last route audit entry. A
  foreign or unpublished scope is not-found and a lost database connection is
  unavailable, and the two are never presented as each other.

  The header states saved identity, not draft identity: the badge, the name, the
  mode and the `Agency · Route ID · Last saved` line all read the saved route and
  its last audit entry, and a route with no audit entry reads as unknown/imported
  attribution rather than borrowing a recent actor. The form controls are the
  shared stateless ones (`RouteFormComponents`), so Details and the create drawer
  cannot drift into two field grammars, and nothing here writes: saving, dirty
  preview, conflicts and lifecycle actions belong to later steps.
  """
  use GtfsPlannerWeb, :live_view
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Components.RouteIdentity
  alias GtfsPlannerWeb.Gtfs.RouteFormComponents
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Route Details")
     |> assign(:user_roles, user_roles)
     |> assign(:active_tab, :details)
     |> assign(:route_state, :loading)
     |> assign(:focus_heading?, false)
     |> assign(:route_form, nil)
     |> assign(:agencies, [])
     |> assign(:mode_counts, [])
     |> assign(:last_saved, nil)}
  end

  @impl true
  def handle_params(%{"route_id" => route_id} = params, _uri, socket) do
    active_tab = socket.assigns[:live_action] || :details

    socket =
      socket
      |> assign(:route_id, route_id)
      |> assign(:active_tab, active_tab)
      # The create drawer lands here with `?created=1`; this is the only arrival
      # that moves focus, so a later tab switch or reload reads normally.
      |> assign(:focus_heading?, params["created"] in ["1", "true"])

    {:noreply, load_route_workspace(socket)}
  end

  @impl true
  def handle_event("retry", _params, socket) do
    {:noreply, load_route_workspace(socket)}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)
    route_id = socket.assigns[:route_id]

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      path =
        if route_id,
          do: ~p"/gtfs/#{version_id}/routes/#{route_id}",
          else: "/gtfs/#{version_id}/routes"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    route_id = socket.assigns[:route_id]

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      path =
        if route_id,
          do: ~p"/gtfs/#{version_id}/routes/#{route_id}",
          else: "/gtfs/#{version_id}/routes"

      {:noreply, push_navigate(socket, to: path)}
    else
      {:noreply, socket}
    end
  end

  # One workspace read, one classification. A missing/foreign scope redirects to
  # the scoped list with a flash and an unavailable database keeps the route on
  # screen behind its retry action; neither is rendered as the other.
  defp load_route_workspace(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.load_route_editor(organization_id, gtfs_version_id, socket.assigns.route_id) do
      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Route not found")
        |> push_navigate(to: "/gtfs/#{gtfs_version_id}/routes")

      {:error, :unavailable} ->
        assign(socket, :route_state, :unavailable)

      {:ok, workspace} ->
        socket
        |> assign(:route, workspace.route)
        |> assign(:source, workspace.source)
        |> assign(:agencies, workspace.agencies)
        |> assign(:mode_counts, workspace.mode_counts)
        |> assign(:last_saved, workspace.last_saved)
        |> assign(:route_form, route_form(workspace.route))
        |> assign(:route_state, :ready)
        |> assign(
          :transfer_count,
          related_transfers(organization_id, gtfs_version_id, workspace.route)
        )
    end
  end

  # The saved route rendered through the same editor changeset a save will use,
  # with no submitted values: the controls read the persisted row, and the form
  # already understands the field grammar the save path validates (R1/R4).
  defp route_form(route) do
    to_form(Route.editor_changeset(route, %{}, :edit), as: :route)
  end

  # "Agency · Route ID · Last saved": the saved agency resolved against this
  # version's agency options (falling back to the stored ID when the option is
  # gone), the natural ID, and the last route audit entry. A route with no audit
  # entry reads as imported/unknown attribution instead of borrowing an actor.
  defp saved_identity(route, agencies, last_saved) do
    [
      agency_label(route, agencies),
      "Route ID #{route.route_id}",
      "Last saved " <> last_saved_label(last_saved)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp agency_label(%{agency_id: nil}, _agencies), do: nil

  defp agency_label(%{agency_id: agency_id}, agencies) do
    case Enum.find(agencies, &(&1.agency_id == agency_id)) do
      %{agency_name: name} when is_binary(name) and name != "" -> name
      _none -> agency_id
    end
  end

  defp last_saved_label(nil), do: "never — imported or unknown attribution"

  defp last_saved_label(%{saved_at: %DateTime{} = saved_at} = saved) do
    "#{Calendar.strftime(saved_at, "%b %-d, %Y at %H:%M")} UTC by #{actor_label(saved)}"
  end

  defp last_saved_label(%{action: action} = saved), do: "#{action} by #{actor_label(saved)}"

  defp actor_label(%{actor_email: email}) when is_binary(email) and email != "", do: email
  defp actor_label(%{actor_id: actor_id}) when is_binary(actor_id), do: actor_id
  defp actor_label(_saved), do: "unknown attribution"

  # The related-transfer count is a direct facade call, never the catalog adapter
  # (CR-15): the details page's own read may be a substituted adapter, but the
  # count is the same predicate the filtered list uses (CR-4).
  defp related_transfers(organization_id, gtfs_version_id, route) do
    Gtfs.count_general_transfers(organization_id, gtfs_version_id, route: route.route_id)
  end

  # A route's display name follows the GTFS preference order, the same chain the
  # catalog and the create drawer use, so the heading never reads as blank.
  defp route_display_name(route) do
    route.route_long_name || route.route_short_name || route.route_id
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_path={@current_path}
      current_gtfs_version={assigns[:current_gtfs_version]}
      available_versions={assigns[:available_versions] || []}
    >
      <:sub_header :if={@route_state == :ready}>
        <.route_sub_nav
          route={@route}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={@active_tab}
        />
      </:sub_header>

      <%= case @route_state do %>
        <% :unavailable -> %>
          <div class="mt-8">
            <.callout kind="error" title="Route data unavailable" id="route-unavailable">
              We could not load this route. Please try again.
              <button
                id="route-retry"
                phx-click="retry"
                class="btn btn-sm btn-outline mt-2"
              >
                Retry
              </button>
            </.callout>
          </div>
        <% :ready -> %>
          <%= cond do %>
            <% @active_tab == :details -> %>
              <%!-- The reference's two-column Details composition: the form column,
                     and the sticky map column step 30 fills. The disclosure, the
                     field order and the header below are this step's; the map
                     region is reserved and empty on purpose. --%>
              <div
                id="route-details-workspace"
                phx-hook="FormErrorFocus"
                data-focus-on-mount={if @focus_heading?, do: "route-details-heading", else: nil}
                class="mt-7 grid gap-8 pb-10 lg:grid-cols-[minmax(0,560px)_minmax(0,1fr)] xl:gap-12"
              >
                <div class="min-w-0">
                  <%!-- Saved identity: the badge, name, mode and attribution the
                         route actually has now, never a draft. --%>
                  <div id="route-details-header" class="grid gap-2">
                    <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
                      <span id="route-details-badge">
                        <RouteIdentity.route_badge
                          route={@route}
                          class="h-10 min-w-11 text-[20px] font-extrabold"
                        />
                      </span>
                      <h1
                        id="route-details-heading"
                        tabindex="-1"
                        class="min-w-0 text-[32px] font-semibold tracking-[-0.02em] text-strong outline-none"
                      >
                        {route_display_name(@route)}
                      </h1>
                      <span
                        id="route-details-mode-label"
                        class="rounded-badge bg-canvas px-2 py-1 text-[13px] font-[650] leading-none text-default"
                      >
                        {Route.route_type_label(@route.route_type)}
                      </span>
                    </div>
                    <p id="route-details-saved-identity" class="text-[13px] text-muted">
                      {saved_identity(@route, @agencies, @last_saved)}
                    </p>
                  </div>

                  <.form
                    :if={@route_form}
                    for={@route_form}
                    id="route-details-form"
                    novalidate
                    class="mt-5 grid gap-8"
                  >
                    <section
                      aria-labelledby="route-details-identity-title"
                      class="grid gap-6"
                    >
                      <div>
                        <h2
                          id="route-details-identity-title"
                          class="text-base font-bold tracking-normal text-strong"
                        >
                          Name and appearance
                        </h2>
                        <p class="mt-1 text-[13px] text-muted">
                          What riders see in trip planners and on signs.
                        </p>
                      </div>

                      <RouteFormComponents.identity_fields
                        form={@route_form}
                        prefix="route-details"
                        mode_counts={@mode_counts}
                        agency_options={@agencies}
                      />

                      <RouteFormComponents.color_fields
                        form={@route_form}
                        prefix="route-details"
                      />
                    </section>

                    <section
                      aria-labelledby="route-details-rider-title"
                      class="grid gap-6 border-t border-subtle pt-6"
                    >
                      <h2
                        id="route-details-rider-title"
                        class="text-base font-bold tracking-normal text-strong"
                      >
                        Rider information
                      </h2>

                      <RouteFormComponents.rider_fields
                        form={@route_form}
                        prefix="route-details"
                      />
                    </section>

                    <RouteFormComponents.additional_details
                      form={@route_form}
                      prefix="route-details"
                      route_id={@route.route_id}
                    />
                  </.form>

                  <div class="mt-8 border-t border-subtle pt-4">
                    <p class="text-[13px] text-muted">
                      <.link
                        id="route-transfers-link"
                        navigate={
                          ~p"/gtfs/#{@current_gtfs_version.id}/transfers?#{[route: @route.route_id]}"
                        }
                        class="font-[650] text-action underline underline-offset-2 hover:no-underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                      >
                        Transfers here ({@transfer_count})
                      </.link>
                    </p>
                  </div>
                </div>

                <%!-- Step 30 renders the saved route map and its pattern list in
                       this sticky column. It is reserved here and deliberately
                       empty rather than filled with invented geometry. --%>
                <aside
                  id="route-details-map-region"
                  class="min-w-0 lg:sticky lg:top-4 lg:self-start"
                >
                </aside>
              </div>
            <% true -> %>
              <div></div>
          <% end %>
        <% _ -> %>
          <div></div>
      <% end %>
    </Layouts.app>
    """
  end
end
