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
  cannot drift into two field grammars.

  A draft is preview, never truth (R7, C-2, INV-6): every form change re-validates
  the submitted values through the same `Route.editor_changeset/3` a save will use,
  applies the valid changes to the saved row for the header/chip preview, and
  names the changed fields in the sticky save bar. Invalid input keeps the saved
  value and its own error line rather than reaching a style attribute. Nothing
  here writes: persistence, conflicts, and lifecycle actions belong to later steps.
  """
  use GtfsPlannerWeb, :live_view
  alias Ecto.Changeset
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Components.RouteIdentity
  alias GtfsPlannerWeb.Gtfs.RouteFormComponents
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The dirty save bar names the fields a save would change, in the editor's own
  # order, the way the reference names them.
  @detail_field_labels [
    route_short_name: "Route number",
    route_long_name: "Route name",
    route_type: "Mode",
    route_color: "Route color",
    route_text_color: "Text color",
    route_desc: "Description",
    route_url: "Web page",
    agency_id: "Agency",
    route_sort_order: "Display order",
    continuous_pickup: "Pickup between stops",
    continuous_drop_off: "Drop-off between stops",
    network_id: "Network"
  ]

  # The fields the header itself shows, so the "Unsaved preview" chip marks a
  # header that is describing a draft rather than the saved row.
  @preview_fields [
    :route_short_name,
    :route_long_name,
    :route_type,
    :route_color,
    :route_text_color
  ]

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
     |> assign(:last_saved, nil)
     |> assign(:draft_route, nil)
     |> assign(:route_text_mode, nil)
     |> assign(:changed_fields, [])}
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

  # Every form change re-validates the draft and reports which fields a save
  # would change. The draft stays on screen (the invalid values are echoed back),
  # the changed fields drive the sticky save bar, and nothing is written.
  @impl true
  def handle_event("validate_route_details", params, socket) do
    {:noreply, assign_details_draft(socket, detail_attrs(params), :validate)}
  end

  # Step 24 owns the Details save. This boundary exists so the form's Ctrl/Cmd+S
  # shortcut emits one ordinary submit instead of navigating the browser, and so
  # a submitted draft is validated and kept on screen: a rejected draft loses
  # nothing and a no-op submit writes nothing (AC-21). Step 24 replaces the body
  # with the audited update command and its conflict outcomes.
  @impl true
  def handle_event("save_route_details", params, socket) do
    {:noreply, assign_details_draft(socket, detail_attrs(params), :validate)}
  end

  # Cancel restores the saved row and its preview. It is a read of what is
  # already stored, so it writes nothing (AC-19/AC-21).
  @impl true
  def handle_event("discard_route_details", _params, socket) do
    route = socket.assigns.route

    {:noreply,
     socket
     |> assign(:route_form, route_form(route))
     |> assign(:draft_route, route)
     |> assign(:route_text_mode, nil)
     |> assign(:changed_fields, [])}
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
        |> assign(:draft_route, workspace.route)
        |> assign(:route_text_mode, nil)
        |> assign(:changed_fields, [])
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

  # The submitted form data: the `route[...]` fields plus the top-level transient
  # `text_mode` the shared color radios carry (R1 keeps it out of the schema).
  defp detail_attrs(%{"route" => attrs} = payload) when is_map(attrs),
    do: Map.put(attrs, "text_mode", payload["text_mode"])

  defp detail_attrs(payload), do: payload

  # One draft, three projections of it: the form the operator keeps editing, the
  # saved row with the valid changes applied (the header/chip preview), and the
  # fields a save would change (the save bar). The dirty set is the changeset's
  # own changes, so the bar and the save path cannot disagree about what changed.
  defp assign_details_draft(socket, attrs, action) do
    changeset =
      socket.assigns.route
      |> Route.editor_changeset(attrs, :edit)
      |> Map.put(:action, action)

    socket
    |> assign(:route_form, to_form(changeset, as: :route))
    |> assign(:route_text_mode, attrs["text_mode"])
    |> assign(:draft_route, Changeset.apply_changes(changeset))
    |> assign(:changed_fields, changed_fields(changeset))
  end

  defp changed_fields(changeset) do
    changed = Map.keys(changeset.changes)

    for {field, _label} <- @detail_field_labels, field in changed, do: field
  end

  defp changed_field_labels(fields) do
    for {field, label} <- @detail_field_labels, field in fields, do: label
  end

  # "Unsaved: Route color · Ctrl+S saves", with the reference's three-name
  # limit, so the bar stays one line at 375px.
  defp changed_fields_summary(fields) do
    labels = changed_field_labels(fields)

    Enum.join(Enum.take(labels, 3), ", ") <> more_labels(length(labels))
  end

  defp more_labels(count) when count > 3, do: " and #{count - 3} more"
  defp more_labels(_count), do: ""

  defp preview?(fields), do: Enum.any?(fields, &(&1 in @preview_fields))

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
                         route actually has now. While a draft differs, the badge,
                         name and mode preview the draft and the chip says so; the
                         attribution line stays saved truth (AC-19, INV-6). --%>
                  <div id="route-details-header" class="grid gap-2">
                    <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
                      <span id="route-details-badge">
                        <RouteIdentity.route_badge
                          route={@draft_route}
                          class="h-10 min-w-11 text-[20px] font-extrabold"
                        />
                      </span>
                      <h1
                        id="route-details-heading"
                        tabindex="-1"
                        class="min-w-0 text-[32px] font-semibold tracking-[-0.02em] text-strong outline-none"
                      >
                        {route_display_name(@draft_route)}
                      </h1>
                      <span
                        id="route-details-mode-label"
                        class="rounded-badge bg-canvas px-2 py-1 text-[13px] font-[650] leading-none text-default"
                      >
                        {Route.route_type_label(@draft_route.route_type)}
                      </span>
                      <span
                        :if={preview?(@changed_fields)}
                        id="route-details-unsaved-preview"
                        class="inline-flex items-center gap-1.5 rounded-badge bg-warning-bg px-2 py-1 text-[13px] font-[650] leading-none text-warning-fg"
                      >
                        <.icon name="hero-pencil-square" class="size-3.5" />Unsaved preview
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
                    phx-change="validate_route_details"
                    phx-submit="save_route_details"
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
                        text_mode={@route_text_mode}
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

                    <%!-- The reference's sticky save bar: it appears only when a
                           draft differs from the saved row, names the fields a
                           save would change, and offers Discard and Save. Save is
                           an ordinary submit, so Ctrl/Cmd+S (wired in the route
                           details editor hook) submits the same way. --%>
                    <div
                      id="route-details-save-bar"
                      hidden={@changed_fields == []}
                      class="sticky bottom-0 z-20 flex flex-wrap items-center gap-x-4 gap-y-2 border-t border-subtle bg-white px-4 py-3 shadow-[0_-8px_24px_#0a13300d]"
                    >
                      <p
                        id="route-details-save-bar-text"
                        class="min-w-0 flex-1 basis-[220px] text-[13px] text-default"
                      >
                        <span class="font-[650] text-strong">Unsaved:</span> {changed_fields_summary(
                          @changed_fields
                        )} <span class="text-muted">· Ctrl+S saves</span>
                      </p>
                      <.button
                        id="route-details-discard"
                        type="button"
                        variant="secondary"
                        class="min-h-11"
                        phx-click="discard_route_details"
                      >
                        Discard changes
                      </.button>
                      <.button
                        type="submit"
                        id="route-save"
                        class="min-h-11 min-w-[140px]"
                        phx-disable-with="Saving…"
                      >
                        Save changes
                      </.button>
                    </div>
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
