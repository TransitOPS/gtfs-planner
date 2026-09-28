defmodule GtfsPlannerWeb.Gtfs.RoutesLive do
  @moduledoc """
  LiveView for browsing GTFS routes.
  Requires pathways_studio_editor role.
  """
  use GtfsPlannerWeb, :live_view
  alias Ecto.Changeset
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Components.RouteIdentity
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The keys stay strings because LiveView params are string-keyed; an atom list
  # would make `Map.take/2` return `%{}`.
  @new_route_fields ~w(route_id route_type route_short_name route_long_name agency_id route_desc route_url route_color route_text_color)
  @new_route_param_keys @new_route_fields ++ Enum.map(@new_route_fields, &("_unused_" <> &1))

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Routes")
     |> assign(:user_roles, user_roles)
     |> assign(:available_route_types, [])
     |> assign(:available_agencies, [])
     |> assign(:filter_form, to_form(%{"route_type" => "", "agency_id" => "", "active" => ""}))
     |> assign(:search_form, to_form(%{"search" => ""}))
     |> assign(:search, "")
     |> assign(:sort_by, :route_id)
     |> assign(:sort_dir, :asc)
     |> assign(:page, 1)
     |> assign(:per_page, 50)
     |> assign(:total_count, 0)
     |> assign(:routes_empty?, true)
     |> assign(:routes_state, :ready)
     |> assign(:new_route_form, nil)
     |> assign(:agency_options, [])
     |> assign(:new_route_agency_required?, false)
     |> stream(:routes, [])
     |> stream(:routes_mobile, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    route_type = parse_route_type(params["route_type"])
    agency_id = parse_string(params["agency_id"])
    active = params["active"]
    search = params["search"] || ""
    sort_by = parse_atom(params["sort_by"], :route_id)
    sort_dir = parse_atom(params["sort_dir"], :asc)
    page = parse_integer(params["page"], 1)
    per_page = socket.assigns.per_page

    opts = [
      route_type: route_type,
      agency_id: agency_id,
      active: active,
      search: search,
      sort_by: sort_by,
      sort_dir: sort_dir,
      page: page,
      per_page: per_page
    ]

    filter_form_data = %{
      "route_type" => params["route_type"] || "",
      "agency_id" => params["agency_id"] || "",
      "active" => params["active"] || ""
    }

    socket =
      socket
      |> assign(:filter_form, to_form(filter_form_data))
      |> assign(:search_form, to_form(%{"search" => search}))
      |> assign(:search, search)
      |> assign(:sort_by, sort_by)
      |> assign(:sort_dir, sort_dir)

    case Gtfs.load_route_catalog(organization_id, gtfs_version_id, opts) do
      {:ok,
       %{
         rows: routes,
         total_count: total_count,
         page: canonical_page,
         route_types: route_types,
         agencies: agencies
       }} ->
        socket =
          socket
          |> assign(:page, canonical_page)
          |> assign(:total_count, total_count)
          |> assign(:available_route_types, route_types)
          |> assign(:available_agencies, agencies)
          |> assign(:routes_empty?, routes == [])
          |> assign(:routes_state, :ready)
          |> stream(:routes, routes, reset: true)
          |> stream(:routes_mobile, routes, reset: true)

        if canonical_page != page do
          query_params = build_query_params(socket, canonical_page)

          {:noreply,
           push_patch(socket,
             to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}"
           )}
        else
          {:noreply, socket}
        end

      {:error, :unavailable} ->
        {:noreply,
         socket
         |> assign(:routes_empty?, true)
         |> assign(:routes_state, :unavailable)
         |> stream(:routes, [], reset: true)
         |> stream(:routes_mobile, [], reset: true)}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    route_type = params["route_type"]
    agency_id = params["agency_id"]
    active = params["active"]

    query_params =
      %{}
      |> maybe_put("route_type", route_type)
      |> maybe_put("agency_id", agency_id)
      |> maybe_put("active", active)
      |> maybe_put("search", socket.assigns.search)
      |> maybe_put_sort(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}"
     )}
  end

  @impl true
  def handle_event("search", %{"search" => term}, socket) do
    query_params =
      %{}
      |> maybe_put("search", term)
      |> maybe_put("route_type", socket.assigns.filter_form.params["route_type"])
      |> maybe_put("agency_id", socket.assigns.filter_form.params["agency_id"])
      |> maybe_put("active", socket.assigns.filter_form.params["active"])
      |> maybe_put_sort(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}"
     )}
  end

  @impl true
  def handle_event("sort", %{"key" => column}, socket) do
    column_atom = parse_column_atom(column)
    current_sort_by = socket.assigns.sort_by
    current_sort_dir = socket.assigns.sort_dir

    {new_sort_by, new_sort_dir} =
      if column_atom == current_sort_by do
        case current_sort_dir do
          :asc -> {current_sort_by, :desc}
          :desc -> {:route_id, :asc}
        end
      else
        {column_atom, :asc}
      end

    query_params =
      %{}
      |> maybe_put("route_type", socket.assigns.filter_form.params["route_type"])
      |> maybe_put("agency_id", socket.assigns.filter_form.params["agency_id"])
      |> maybe_put("active", socket.assigns.filter_form.params["active"])
      |> maybe_put("search", socket.assigns.search)
      |> maybe_put_sort(new_sort_by, new_sort_dir)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}"
     )}
  end

  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    page_num = parse_integer(page, 1)

    query_params = build_query_params(socket, page_num)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}"
     )}
  end

  @impl true
  def handle_event("retry", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    opts = [
      route_type: parse_route_type(socket.assigns.filter_form.params["route_type"]),
      agency_id: parse_string(socket.assigns.filter_form.params["agency_id"]),
      active: socket.assigns.filter_form.params["active"],
      search: socket.assigns.search,
      sort_by: socket.assigns.sort_by,
      sort_dir: socket.assigns.sort_dir,
      page: socket.assigns.page,
      per_page: socket.assigns.per_page
    ]

    case Gtfs.load_route_catalog(organization_id, gtfs_version_id, opts) do
      {:ok,
       %{
         rows: routes,
         total_count: total_count,
         page: canonical_page,
         route_types: route_types,
         agencies: agencies
       }} ->
        {:noreply,
         socket
         |> assign(:page, canonical_page)
         |> assign(:total_count, total_count)
         |> assign(:available_route_types, route_types)
         |> assign(:available_agencies, agencies)
         |> assign(:routes_empty?, routes == [])
         |> assign(:routes_state, :ready)
         |> stream(:routes, routes, reset: true)
         |> stream(:routes_mobile, routes, reset: true)}

      {:error, :unavailable} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_filter", %{"key" => key}, socket) do
    # A chip dismisses one constraint and keeps the rest, so the patch carries
    # every other active filter along with it.
    params = socket.assigns.filter_form.params

    query_params =
      if key in ~w(route_type agency_id active) do
        # The form params carry blank strings for unselected selects; drop them
        # so dismissing one chip does not re-add the others as empty query params.
        params
        |> Map.put(key, "")
        |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
        |> Map.new()
        |> maybe_put("search", socket.assigns.search)
        |> maybe_put_sort(socket.assigns.sort_by, socket.assigns.sort_dir)
      else
        build_query_params(socket, socket.assigns.page)
      end

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{query_params}"
     )}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes"
     )}
  end

  @impl true
  def handle_event("open_new_route", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    agency_options = list_agency_options(organization_id, gtfs_version_id)

    form =
      %Route{}
      |> Route.changeset(%{"agency_id" => default_agency_id(socket, agency_options)})
      |> to_form(as: :route)

    {:noreply,
     socket
     |> assign(:agency_options, agency_options)
     |> assign(:new_route_agency_required?, false)
     |> assign(:new_route_form, form)}
  end

  @impl true
  def handle_event("validate_new_route", %{"route" => params}, socket) do
    if is_nil(socket.assigns.new_route_form) do
      {:noreply, socket}
    else
      form =
        socket
        |> new_route_changeset(new_route_attrs(socket, params))
        |> Map.put(:action, :validate)
        |> to_form(as: :route)

      {:noreply, assign(socket, :new_route_form, form)}
    end
  end

  @impl true
  def handle_event("validate_new_route", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("close_new_route", _params, socket) do
    {:noreply, close_new_route(socket)}
  end

  @impl true
  def handle_event("save_new_route", %{"route" => params}, socket) do
    cond do
      is_nil(socket.assigns.new_route_form) ->
        # A replayed or late submit after the drawer closed must not insert.
        {:noreply, socket}

      not editor_access?(socket) ->
        {:noreply,
         socket
         |> close_new_route()
         |> put_flash(
           :error,
           "Route not created: you no longer have editor access to this organization."
         )}

      true ->
        create_new_route(socket, params)
    end
  end

  @impl true
  def handle_event("save_new_route", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/routes")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/routes")}
    else
      {:noreply, socket}
    end
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
      <:sub_header>
        <.routes_tabs gtfs_version_id={@current_gtfs_version.id} active_tab={:routes} />
      </:sub_header>

      <.header>
        Routes
        <:subtitle>GTFS routes for the current version</:subtitle>
        <:actions>
          <.button
            :if={@routes_state == :ready}
            id="new-route-trigger"
            type="button"
            phx-click="open_new_route"
            variant={if(first_use_empty?(assigns), do: "secondary", else: "primary")}
            class="min-h-11"
          >
            <.icon name="hero-plus" class="size-4" /> Create route
          </.button>
        </:actions>
      </.header>

      <%!-- Catalog read failed ({:error, :unavailable}): the card is replaced by
             the error block so a partially-rendered table never appears. --%>
      <div :if={@routes_state == :unavailable} id="routes-unavailable" class="mt-6">
        <.callout kind="error" title="Route catalog unavailable">
          The route catalog is temporarily unavailable. Please try again.
          <.button
            id="routes-retry"
            phx-click="retry"
            variant="secondary"
            size="sm"
            class="mt-2"
          >
            Retry
          </.button>
        </.callout>
      </div>

      <section
        :if={@routes_state != :unavailable}
        id="routes-workbench"
        aria-label="Route catalog"
        class="mt-6 overflow-clip rounded-card border border-subtle bg-white"
      >
        <%!-- Search and filters form one toolbar: search is used on almost every
               visit, so it takes the width; the three selects less often. The two
               server forms keep the IDs the tests reach for. --%>
        <div
          id="routes-toolbar"
          role="search"
          class="flex flex-wrap items-end gap-3 border-b border-subtle px-4 py-4 md:px-5"
        >
          <div class="min-w-0 flex-1 basis-[190px] md:basis-[280px]">
            <.form for={@search_form} id="route-search-form" phx-change="search">
              <.input
                field={@search_form[:search]}
                type="search"
                label="Search routes"
                placeholder="Search names and IDs"
                phx-debounce="300"
                class="h-11 w-full rounded-control border border-control bg-white px-3 text-sm text-strong placeholder:text-muted"
              />
            </.form>
          </div>

          <span
            :if={active_filter_count(assigns) > 0}
            class="inline-flex min-h-11 items-center rounded-badge bg-selection px-2 text-[13px] font-bold tabular-nums text-action md:hidden"
            aria-hidden="true"
          >
            {active_filter_count(assigns)}
          </span>

          <.form
            for={@filter_form}
            id="route-filter-form"
            phx-change="filter"
            class="flex w-full flex-wrap items-end gap-3 max-md:order-last md:w-auto"
          >
            <div class="min-w-0 flex-1 basis-[140px] md:w-[168px] md:flex-none">
              <.input
                field={@filter_form[:route_type]}
                type="select"
                label="Mode"
                prompt="All modes"
                options={
                  Enum.map(@available_route_types || [], fn type ->
                    {Route.route_type_label(type), type}
                  end)
                }
                class="h-11 w-full appearance-none rounded-control border border-control bg-white pl-3 pr-9 text-sm text-strong"
              />
            </div>
            <div class="min-w-0 flex-1 basis-[140px] md:w-[168px] md:flex-none">
              <.input
                field={@filter_form[:active]}
                type="select"
                label="Status"
                options={[{"All statuses", ""}, {"Active", "true"}, {"Inactive", "false"}]}
                class="h-11 w-full appearance-none rounded-control border border-control bg-white pl-3 pr-9 text-sm text-strong"
              />
            </div>
            <div class="min-w-0 flex-1 basis-[140px] md:w-[168px] md:flex-none">
              <.input
                field={@filter_form[:agency_id]}
                type="select"
                label="Agency"
                prompt="All agencies"
                options={Enum.map(@available_agencies || [], fn agency -> {agency, agency} end)}
                class="h-11 w-full appearance-none rounded-control border border-control bg-white pl-3 pr-9 text-sm text-strong"
              />
            </div>
          </.form>
        </div>

        <%!-- Result count and active constraints; each constraint can be removed
               on its own. --%>
        <div
          id="routes-summary"
          class="flex min-h-[52px] flex-wrap items-center gap-x-3 gap-y-1 border-b border-subtle px-4 py-1 text-[13px] md:px-5"
        >
          <p id="routes-count" role="status" class="font-[650] tabular-nums text-strong">
            {route_count_text(@routes_state, @total_count)}
          </p>

          <div id="routes-chips" class="flex flex-wrap items-center gap-2">
            <.constraint_chip
              :for={filter <- active_filters(assigns)}
              id={"routes-chip-#{filter.key}"}
              key={filter.key}
              label={filter.label}
            />
          </div>

          <button
            :if={has_active_constraints?(assigns) and not @routes_empty?}
            id="routes-clear-filters"
            type="button"
            phx-click="clear_filters"
            class="ml-auto inline-flex min-h-11 items-center font-[650] text-action hover:underline"
          >
            {if only_search_active?(assigns), do: "Clear search", else: "Clear filters"}
          </button>
        </div>

        <div id="routes-results">
          <%!-- Desktop and tablet: semantic table. --%>
          <div
            :if={not @routes_empty?}
            id="routes-container"
            class="max-md:hidden overflow-x-auto"
          >
            <table class="workbench-table ds-stack-table">
              <thead>
                <tr>
                  <.sort_header
                    label="Route"
                    sort_key="route_short_name"
                    sort_by={@sort_by}
                    sort_dir={@sort_dir}
                    class="w-[104px] py-0 pl-5 pr-2"
                  />
                  <.sort_header
                    label="Name"
                    sort_key="route_long_name"
                    sort_by={@sort_by}
                    sort_dir={@sort_dir}
                    class="px-4 py-0"
                  />
                  <.sort_header
                    label="Mode"
                    sort_key="route_type"
                    sort_by={@sort_by}
                    sort_dir={@sort_dir}
                    class="w-[176px] px-4 py-0"
                  />
                  <.sort_header
                    label="Route ID"
                    sort_key="route_id"
                    sort_by={@sort_by}
                    sort_dir={@sort_dir}
                    class="w-[200px] py-0 pl-4 pr-5"
                  />
                </tr>
              </thead>
              <tbody id="routes" phx-update="stream">
                <tr
                  :for={{id, route} <- @streams.routes}
                  id={id}
                  class="cursor-pointer hover:bg-canvas/70"
                >
                  <td class="py-2 pl-5 pr-2">
                    <RouteIdentity.route_badge
                      route={route}
                      class="min-h-[26px] min-w-[30px] text-[13px]"
                    />
                  </td>
                  <td class="px-4 py-2">
                    <div class="flex items-center gap-2">
                      <span class="text-strong">{route_display_name(route)}</span>
                      <span
                        :if={not route.active}
                        class="inline-flex items-center rounded-badge bg-canvas px-1.5 text-[13px] font-[650] text-muted"
                      >
                        Inactive
                      </span>
                    </div>
                  </td>
                  <td class="px-4 py-2 text-default">
                    {Route.route_type_label(route.route_type)}
                  </td>
                  <td class="py-2 pl-4 pr-5">
                    <.link
                      navigate={"/gtfs/#{@current_gtfs_version.id}/routes/#{route.route_id}"}
                      class="link link-primary font-mono font-semibold tabular-nums"
                    >
                      {route.route_id}
                    </.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- Phones: one list item per route, whole item is the link. --%>
          <ul
            :if={not @routes_empty?}
            id="routes-list"
            phx-update="stream"
            class="workbench-list md:hidden"
          >
            <li
              :for={{id, route} <- @streams.routes_mobile}
              id={id}
              class="border-b border-subtle last:border-b-0"
            >
              <.link
                navigate={"/gtfs/#{@current_gtfs_version.id}/routes/#{route.route_id}"}
                class="flex min-h-11 items-center gap-3 px-4 py-3 hover:bg-canvas"
              >
                <RouteIdentity.route_badge
                  route={route}
                  class="min-h-[26px] min-w-[30px] text-[13px]"
                />
                <span class="min-w-0 flex-1">
                  <span class="block truncate text-sm font-[650] text-strong">
                    {route_display_name(route)}
                  </span>
                  <span class="block truncate text-[13px] text-muted">
                    {Route.route_type_label(route.route_type)}
                    <span :if={not route.active}> · Inactive</span>
                  </span>
                </span>
                <.icon name="hero-chevron-right" class="size-5 shrink-0 text-subtle" />
              </.link>
            </li>
          </ul>

          <%!-- Search or filters exclude every route. --%>
          <div
            :if={@routes_empty? and has_active_constraints?(assigns)}
            id="routes-constrained-empty"
            class="px-5 py-12 text-center"
          >
            <h2 class="font-sans text-base font-bold tracking-normal text-strong">
              No routes match {constraint_summary(assigns)}
            </h2>
            <p class="mx-auto mt-1.5 max-w-[46ch] text-sm text-muted">
              Check the spelling, or clear the search to see every route.
            </p>
            <button
              id="routes-clear-filters"
              type="button"
              phx-click="clear_filters"
              class="mt-5 inline-flex min-h-11 items-center justify-center rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas"
            >
              {if only_search_active?(assigns), do: "Clear search", else: "Clear filters"}
            </button>
          </div>

          <%!-- No routes in this version at all: the catalog is empty, not
                 filtered, so the next step is to import a feed. --%>
          <div :if={first_use_empty?(assigns)} id="routes-first-use-empty" class="px-5 py-14 sm:px-10">
            <div class="mx-auto max-w-[520px] text-center">
              <h2 class="text-[24px]">No routes in this version yet</h2>
              <p class="mt-2 text-sm text-muted">
                Routes appear here after you import a GTFS feed or create a route.
              </p>
              <div class="mt-6 flex flex-wrap justify-center gap-3">
                <.link
                  navigate={~p"/gtfs/#{@current_gtfs_version.id}/import"}
                  class="btn btn-primary min-h-11 border-none bg-action text-white hover:bg-action-hover"
                >
                  <.icon name="hero-arrow-up-tray" class="size-4" /> Import feed
                </.link>
                <.button
                  id="first-use-create"
                  type="button"
                  phx-click="open_new_route"
                  variant="secondary"
                  class="min-h-11"
                >
                  Create route
                </.button>
              </div>
            </div>
          </div>
        </div>

        <div
          :if={not @routes_empty? and @total_count > 0}
          class="border-t border-subtle px-4 md:px-5"
        >
          <.pagination page={@page} per_page={@per_page} total={@total_count} entity="routes" />
        </div>
      </section>

      <.new_route_drawer
        form={@new_route_form}
        agency_options={@agency_options}
        agency_required?={@new_route_agency_required?}
        gtfs_version_id={@current_gtfs_version.id}
      />
    </Layouts.app>
    """
  end

  # ── Workbench pieces ────────────────────────────────────────────────────────
  #
  # The redesign (tmp/redesign/routes.html) folds search, filters, results and
  # pagination into one "workbench" card, following the design system's
  # `.workbench` pattern. The markup lives in `render/1` so every part of the
  # card reads the same assigns; only these two markup helpers are separate.

  # A chip dismisses one constraint. It is labeled with the value the operator
  # chose, not the raw query param, and its `aria-label` spells out the action.
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :key, :string, required: true, doc: "the query param this chip dismisses"

  defp constraint_chip(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="remove_filter"
      phx-value-key={@key}
      class="inline-flex min-h-11 items-center gap-1.5 rounded-badge border border-subtle bg-white pl-2.5 pr-2 text-[13px] font-[650] text-strong hover:bg-canvas"
      aria-label={"Remove filter #{@label}"}
    >
      {@label}
      <.icon name="hero-x-mark" class="size-3.5 text-muted" />
    </button>
    """
  end

  # The table's own sort header, so the desktop table can carry the workbench
  # styling (sticky canvas header, 44px targets) without the shared `<.table>`
  # component's daisyUI chrome.
  attr :label, :string, required: true
  attr :sort_key, :string, required: true
  attr :sort_by, :atom, required: true
  attr :sort_dir, :atom, required: true
  attr :class, :string, default: ""

  defp sort_header(assigns) do
    state =
      column_sort_state(
        assigns.sort_by,
        assigns.sort_dir,
        String.to_existing_atom(assigns.sort_key)
      )

    assigns =
      assigns
      |> assign(:state, state)
      |> assign(:aria_sort, aria_sort_value(state))
      |> assign(:indicator, sort_indicator(state))

    ~H"""
    <th
      scope="col"
      aria-sort={@aria_sort}
      class={[
        "sticky top-0 z-10 border-b border-subtle bg-canvas text-[13px] font-[650] text-default",
        @class
      ]}
    >
      <button
        type="button"
        phx-click="sort"
        phx-value-key={@sort_key}
        class="inline-flex min-h-11 items-center gap-1.5 hover:text-strong hover:underline"
      >
        {@label}<span aria-hidden="true">{@indicator}</span>
      </button>
    </th>
    """
  end

  # A route's display name follows the GTFS preference order; the fallback chain
  # ends at route_id, which is always present, so a cell is never blank.
  defp route_display_name(route) do
    route.route_long_name || route.route_short_name || route.route_id
  end

  defp route_count_text(:ready, count), do: "#{count} #{pluralize(count, "route")}"
  defp route_count_text(:unavailable, _count), do: "Routes could not load"

  defp pluralize(1, singular), do: singular
  defp pluralize(_count, singular), do: "#{singular}s"

  # The summary row repeats each active constraint as a removable chip, so it
  # needs the value, not the param. Status reads as a word; mode maps through the
  # same label helper the rest of the page uses.
  defp active_filters(assigns) do
    params = assigns.filter_form.params

    # One tuple per constraint: its query key, whether it is set, and the label
    # the chip shows — the chosen value, not the raw param.
    filters = [
      {"search", assigns.search != "", "\"" <> assigns.search <> "\""},
      {"route_type", present?(params["route_type"]),
       Route.route_type_label(parse_route_type(params["route_type"]))},
      {"active", params["active"] in ~w(true false), status_label(params["active"])},
      {"agency_id", present?(params["agency_id"]), params["agency_id"]}
    ]

    for {key, true, label} <- filters, do: %{key: key, label: label}
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp status_label("true"), do: "Active"
  defp status_label("false"), do: "Inactive"
  defp status_label(_other), do: nil

  defp active_filter_count(assigns), do: length(active_filters(assigns))

  defp only_search_active?(assigns) do
    assigns.search != "" and no_filter_active?(assigns)
  end

  # The no-match heading names the constraints that excluded everything, which
  # is what the operator needs to loosen.
  defp constraint_summary(assigns) do
    case active_filters(assigns) do
      [] -> "your filters"
      [single] -> single.label
      many -> Enum.map_join(many, ", ", & &1.label)
    end
  end

  attr :form, :any, default: nil
  attr :agency_options, :list, default: []
  attr :agency_required?, :boolean, default: false
  attr :gtfs_version_id, :string, required: true

  defp new_route_drawer(assigns) do
    ~H"""
    <.drawer
      id="new-route-drawer"
      open={not is_nil(@form)}
      on_close="close_new_route"
      title="New route"
      initial_focus={:first_field}
      return_focus_id="new-route-trigger"
      class="max-w-[min(100vw,40rem)]"
    >
      <div id="new-route-form-panel" phx-hook="FormErrorFocus">
        <div :if={@agency_required?} class="mb-4">
          <.callout
            id="new-route-agency-required"
            kind="warning"
            title="This version has no agency"
            tabindex="-1"
          >
            Add the agency that operates this route in Settings › Agencies, then create the route
            again. Nothing was saved.
            <.link
              id="new-route-agency-settings"
              navigate={agencies_path(@gtfs_version_id)}
              class="mt-2 block font-medium text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
            >
              Open Settings › Agencies
            </.link>
          </.callout>
        </div>

        <.new_route_form :if={@form} form={@form} agency_options={@agency_options} />
      </div>
    </.drawer>
    """
  end

  attr :form, :any, required: true
  attr :agency_options, :list, required: true

  defp new_route_form(assigns) do
    assigns =
      assign(
        assigns,
        :show_errors?,
        assigns.form.source.action == :insert and not assigns.form.source.valid?
      )

    ~H"""
    <.form
      for={@form}
      id="new-route-form"
      novalidate
      phx-change="validate_new_route"
      phx-submit="save_new_route"
      class="space-y-1"
    >
      <div :if={@show_errors?} class="mb-4">
        <.callout
          id="new-route-form-error"
          kind="error"
          title="Check the highlighted fields"
          tabindex="-1"
        >
          Nothing was saved. Correct the fields marked below, then create the route again.
        </.callout>
      </div>

      <div class="sm:max-w-[20rem]">
        <.input
          field={@form[:route_id]}
          type="text"
          label="Route ID"
          phx-debounce="blur"
          help="route_id — unique within this GTFS version, such as 32 or RED."
        />
      </div>

      <div class="sm:max-w-[16rem]">
        <.input
          field={@form[:route_short_name]}
          type="text"
          label="Short name"
          phx-debounce="blur"
          help="route_short_name — the short label riders see, such as 32. Enter a short name, a long name, or both."
        />
      </div>

      <.input
        field={@form[:route_long_name]}
        type="text"
        label="Long name"
        phx-debounce="blur"
        help="route_long_name — the full name, such as Downtown – Airport."
      />

      <div class="sm:max-w-[20rem]">
        <.input
          field={@form[:route_type]}
          type="select"
          label="Mode"
          prompt="Select a mode"
          options={Route.route_type_options()}
          help="route_type — the kind of vehicle that serves this route."
        />
      </div>

      <div :if={@agency_options != []} class="sm:max-w-[24rem]">
        <.input
          field={@form[:agency_id]}
          type="select"
          label="Agency"
          prompt={agency_prompt(@form, @agency_options)}
          options={@agency_options}
          help="agency_id — the agency that operates this route."
        />
      </div>

      <.input
        field={@form[:route_desc]}
        type="textarea"
        label="Description (optional)"
        phx-debounce="blur"
        help="route_desc — extra detail for riders, such as service hours or major stops."
      />

      <.input
        field={@form[:route_url]}
        type="url"
        label="URL (optional)"
        phx-debounce="blur"
        help="route_url — a web page about this route, such as https://example.com/routes/32."
      />

      <div class="grid gap-x-4 sm:grid-cols-2">
        <.input
          field={@form[:route_color]}
          type="text"
          label="Route color (optional)"
          phx-debounce="blur"
          help="route_color — six hex digits without #, such as 0055A4. Blank uses FFFFFF."
        />
        <.input
          field={@form[:route_text_color]}
          type="text"
          label="Text color (optional)"
          phx-debounce="blur"
          help="route_text_color — six hex digits without #. Blank uses 000000."
        />
      </div>

      <div class="flex flex-wrap items-center justify-end gap-3 pt-3">
        <.button
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="close_new_route"
        >
          Cancel
        </.button>
        <.button
          type="submit"
          id="new-route-submit"
          class="min-h-11"
          phx-disable-with="Creating…"
        >
          Create route
        </.button>
      </div>
    </.form>
    """
  end

  defp first_use_empty?(assigns) do
    assigns.routes_state == :ready and assigns.routes_empty? and
      not has_active_constraints?(assigns)
  end

  defp new_route_attrs(socket, params) do
    # `Route.changeset/2` casts the scope columns, so this allow-list is the
    # tenant boundary. `_unused_*` keys are kept for `used_input?/1` and ignored
    # by `cast`.
    params
    |> Map.take(@new_route_param_keys)
    |> Map.put("organization_id", socket.assigns.current_organization.id)
    |> Map.put("gtfs_version_id", socket.assigns.current_gtfs_version.id)
  end

  defp list_agency_options(organization_id, gtfs_version_id) do
    organization_id
    |> Gtfs.list_agencies(gtfs_version_id)
    |> Enum.map(&{"#{&1.agency_name} (#{&1.agency_id})", &1.agency_id})
  end

  # The drawer opens with the agency already chosen when the version leaves no
  # real choice: its own only agency, or the agency the catalog is filtered to.
  defp default_agency_id(socket, agency_options) do
    agency_ids = Enum.map(agency_options, &elem(&1, 1))
    filtered_id = socket.assigns.filter_form.params["agency_id"]

    cond do
      match?([_], agency_ids) -> hd(agency_ids)
      filtered_id in agency_ids -> filtered_id
      true -> nil
    end
  end

  # "Choose agency" is only a choice when there is one to make (AC-23).
  defp agency_prompt(form, agency_options) do
    if length(agency_options) > 1 and form[:agency_id].value in [nil, ""] do
      "Choose agency"
    end
  end

  defp agencies_path(version_id), do: "/gtfs/#{version_id}/settings/agencies"

  defp new_route_changeset(socket, attrs) do
    changeset = Route.changeset(%Route{}, attrs)

    # Only the drawer's own blank choice is required here: with several agencies
    # it offers no default, so nothing was chosen. The zero/one/many agency rule
    # belongs to `GtfsPlanner.Gtfs.FeedSettings.lock_agency_for_reference!/3`,
    # which `Gtfs.create_version_route/3` calls inside the insert's own
    # transaction (R4, INV-1) — and there a blank choice resolves to the version's
    # single agency, so this must not refuse that case.
    if length(socket.assigns.agency_options) > 1 do
      Changeset.validate_required(changeset, [:agency_id])
    else
      changeset
    end
  end

  defp close_new_route(socket) do
    socket
    |> assign(:new_route_form, nil)
    |> assign(:agency_options, [])
    |> assign(:new_route_agency_required?, false)
  end

  defp create_new_route(socket, params) do
    attrs = new_route_attrs(socket, params)

    with {:ok, _validated} <-
           socket |> new_route_changeset(attrs) |> Changeset.apply_action(:insert),
         {:ok, route} <-
           Gtfs.create_version_route(
             socket.assigns.current_organization.id,
             socket.assigns.current_gtfs_version.id,
             attrs
           ) do
      # The patch re-enters `handle_params/3`, which reloads the catalog with
      # the current query.
      {:noreply,
       socket
       |> close_new_route()
       |> put_flash(:info, "Route #{route.route_id} created.")
       |> push_patch(
         to:
           ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/routes?#{build_query_params(socket, socket.assigns.page)}"
       )}
    else
      {:error, %Changeset{} = changeset} ->
        show_new_route_error(socket, changeset)

      # The version's agency set moved between opening the drawer and saving, so
      # the context's own answer is the one that lands on the field. The refusal
      # is rebuilt from what was submitted and carries an action, because Phoenix
      # drops the errors of a changeset that has none.
      {:error, :agency_not_found} ->
        show_new_route_error(
          socket,
          socket
          |> new_route_changeset(attrs)
          |> Changeset.add_error(:agency_id, "is not an agency in this version")
          |> Map.put(:action, :validate)
        )

      {:error, :agency_required} ->
        # The editor clicked Create route at the bottom of a long drawer, so the
        # refusal has to be brought into view rather than inserted above it.
        {:noreply,
         socket
         |> assign(:new_route_agency_required?, true)
         |> push_event("focus_scoped_target", %{id: "new-route-agency-required"})}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> close_new_route()
         |> put_flash(:error, "This version is no longer available.")}
    end
  end

  defp show_new_route_error(socket, changeset) do
    {:noreply,
     socket
     |> assign(:new_route_form, to_form(changeset, as: :route))
     |> push_event("focus_form_error", %{
       form_id: "new-route-form",
       fallback_id: "new-route-form-error"
     })}
  end

  # Mount-time access is not enough for a write: the membership may have lost
  # the editor role or been deactivated since this socket connected.
  defp editor_access?(socket) do
    with %{id: user_id} <- socket.assigns[:current_user],
         %{id: organization_id} <- socket.assigns[:current_organization],
         %UserOrgMembership{} = membership <-
           Accounts.get_user_org_membership(user_id, organization_id),
         true <- is_nil(membership.deactivated_at) do
      GtfsPlannerWeb.EnsureRole.has_role?(membership.roles, :pathways_studio_editor)
    else
      _other -> false
    end
  end

  defp has_active_constraints?(assigns) do
    search_active = assigns.search != ""
    filter_active = not no_filter_active?(assigns)
    search_active or filter_active
  end

  defp no_filter_active?(assigns) do
    params = assigns.filter_form.params

    params["route_type"] in [nil, ""] and
      params["agency_id"] in [nil, ""] and
      params["active"] in [nil, ""]
  end

  defp build_query_params(socket, page) do
    %{}
    |> maybe_put("route_type", socket.assigns.filter_form.params["route_type"])
    |> maybe_put("agency_id", socket.assigns.filter_form.params["agency_id"])
    |> maybe_put("active", socket.assigns.filter_form.params["active"])
    |> maybe_put("search", socket.assigns.search)
    |> maybe_put("sort_by", socket.assigns.sort_by)
    |> maybe_put("sort_dir", socket.assigns.sort_dir)
    |> Map.put("page", page)
  end

  defp parse_route_type(nil), do: nil
  defp parse_route_type(""), do: nil

  defp parse_route_type(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_string(nil), do: nil
  defp parse_string(""), do: nil
  defp parse_string(value) when is_binary(value), do: value

  defp parse_atom(nil, default), do: default
  defp parse_atom("", default), do: default

  defp parse_atom(value, _default) when is_binary(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> :route_id
    end
  end

  defp parse_integer(nil, default), do: default
  defp parse_integer("", default), do: default

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_sort(map, :route_id, :asc), do: map

  defp maybe_put_sort(map, sort_by, sort_dir) do
    map
    |> Map.put("sort_by", sort_by)
    |> Map.put("sort_dir", sort_dir)
  end

  defp parse_column_atom(column) when is_binary(column) do
    valid_columns = [:route_id, :route_short_name, :route_long_name, :route_type, :active]

    try do
      column_atom = String.to_existing_atom(column)
      if column_atom in valid_columns, do: column_atom, else: :route_id
    rescue
      ArgumentError -> :route_id
    end
  end

  defp column_sort_state(sort_by, sort_dir, column) when column == sort_by do
    case sort_dir do
      :asc -> "asc"
      :desc -> "desc"
    end
  end

  defp column_sort_state(_sort_by, _sort_dir, _column), do: "none"

  defp aria_sort_value("asc"), do: "ascending"
  defp aria_sort_value("desc"), do: "descending"
  defp aria_sort_value(_other), do: "none"

  # ▲ / ▼ read as direction at a glance; an unsorted column gets the neutral
  # double arrow because a single arrow would imply a sort that isn't there.
  defp sort_indicator("asc"), do: "▲"
  defp sort_indicator("desc"), do: "▼"
  defp sort_indicator(_other), do: "↕"
end
