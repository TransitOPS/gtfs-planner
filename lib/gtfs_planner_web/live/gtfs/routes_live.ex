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
     |> stream(:routes, [])}
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
         |> stream(:routes, [], reset: true)}
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
         |> stream(:routes, routes, reset: true)}

      {:error, :unavailable} ->
        {:noreply, socket}
    end
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

    agency_options =
      organization_id
      |> Gtfs.list_agencies(gtfs_version_id)
      |> Enum.map(&{"#{&1.agency_name} (#{&1.agency_id})", &1.agency_id})

    {:noreply,
     socket
     |> assign(:agency_options, agency_options)
     |> assign(:new_route_form, to_form(Route.changeset(%Route{}, %{}), as: :route))}
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
            Create route
          </.button>
        </:actions>
      </.header>

      <div class="mt-6 bg-base-100 border border-base-300 rounded-box p-4">
        <.form
          for={@filter_form}
          id="route-filter-form"
          phx-change="filter"
          class="flex flex-wrap gap-4 items-end"
        >
          <div class="flex-1 min-w-[200px]">
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
            />
          </div>
          <div class="flex-1 min-w-[200px]">
            <.input
              field={@filter_form[:agency_id]}
              type="select"
              label="Agency"
              prompt="All agencies"
              options={Enum.map(@available_agencies || [], fn agency -> {agency, agency} end)}
            />
          </div>
          <div class="flex-1 min-w-[200px]">
            <.input
              field={@filter_form[:active]}
              type="select"
              label="Status"
              options={[{"All statuses", ""}, {"Active", "true"}, {"Inactive", "false"}]}
            />
          </div>
        </.form>

        <div class="mt-4 max-w-md">
          <.form for={@search_form} id="route-search-form" phx-change="search">
            <.input
              field={@search_form[:search]}
              type="search"
              placeholder="Search names and IDs"
              phx-debounce="300"
              label="Search"
            />
            <p class="mt-1 text-xs text-base-content/70">Search names and IDs</p>
          </.form>
        </div>
      </div>

      <div
        :if={@routes_state == :unavailable}
        id="routes-unavailable"
        class="mt-6"
      >
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

      <div
        :if={@routes_state == :ready and @routes_empty? and has_active_constraints?(assigns)}
        id="routes-constrained-empty"
        class="mt-6"
      >
        <.empty_state title="No routes match your filters">
          Try adjusting your search or filter criteria.
          <:action>
            <.button
              id="routes-clear-filters"
              phx-click="clear_filters"
              variant="secondary"
              size="sm"
            >
              {if @search != "" and no_filter_active?(assigns),
                do: "Clear search",
                else: "Clear filters"}
            </.button>
          </:action>
        </.empty_state>
      </div>

      <div :if={first_use_empty?(assigns)} id="routes-first-use-empty" class="mt-6">
        <.empty_state title="No routes yet">
          Routes appear here after you import a GTFS feed or create a route.
          <:action>
            <.link
              navigate={~p"/gtfs/#{@current_gtfs_version.id}/import"}
              class="btn btn-primary btn-sm"
            >
              Import feed
            </.link>
          </:action>
        </.empty_state>
      </div>

      <div :if={@routes_state == :ready and not @routes_empty?} class="mt-6">
        <div class="bg-base-100 border border-base-300 rounded-box overflow-hidden">
          <.table id="routes" rows={@streams.routes} responsive="stack">
            <:col
              :let={{_id, route}}
              label="Route ID"
              sort_key="route_id"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, :route_id)}
            >
              <.link
                navigate={"/gtfs/#{@current_gtfs_version.id}/routes/#{route.route_id}"}
                class="link link-primary font-semibold font-mono"
              >
                {route.route_id}
              </.link>
            </:col>
            <:col
              :let={{_id, route}}
              label="Short Name"
              sort_key="route_short_name"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, :route_short_name)}
            >
              {route.route_short_name || "—"}
            </:col>
            <:col
              :let={{_id, route}}
              label="Long Name"
              sort_key="route_long_name"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, :route_long_name)}
            >
              {route.route_long_name || "—"}
            </:col>
            <:col
              :let={{_id, route}}
              label="Type"
              sort_key="route_type"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, :route_type)}
            >
              {Route.route_type_label(route.route_type)}
            </:col>
            <:col :let={{_id, route}} label="Badge">
              <RouteIdentity.route_badge route={route} />
            </:col>
          </.table>
        </div>

        <.pagination
          :if={@total_count > 0}
          page={@page}
          per_page={@per_page}
          total={@total_count}
          entity="routes"
        />
      </div>

      <.new_route_drawer form={@new_route_form} agency_options={@agency_options} />
    </Layouts.app>
    """
  end

  attr :form, :any, default: nil
  attr :agency_options, :list, default: []

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
          label={if(length(@agency_options) > 1, do: "Agency", else: "Agency (optional)")}
          prompt="None"
          options={@agency_options}
          help="agency_id — required when this version has more than one agency."
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

      <div class="flex flex-wrap items-center gap-3 pt-3">
        <.button
          type="submit"
          id="new-route-submit"
          class="min-h-11"
          phx-disable-with="Creating…"
        >
          Create route
        </.button>
        <.button type="button" variant="quiet" class="min-h-11" phx-click="close_new_route">
          Cancel
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

  defp new_route_changeset(socket, attrs) do
    agency_ids = Enum.map(socket.assigns.agency_options, &elem(&1, 1))

    changeset =
      %Route{}
      |> Route.changeset(attrs)
      |> Changeset.validate_inclusion(:agency_id, agency_ids,
        message: "is not an agency in this version"
      )

    if length(agency_ids) > 1 do
      Changeset.validate_required(changeset, [:agency_id])
    else
      changeset
    end
  end

  defp close_new_route(socket) do
    socket
    |> assign(:new_route_form, nil)
    |> assign(:agency_options, [])
  end

  defp create_new_route(socket, params) do
    attrs = new_route_attrs(socket, params)

    with {:ok, _validated} <-
           socket |> new_route_changeset(attrs) |> Changeset.apply_action(:insert),
         {:ok, route} <- Gtfs.create_route(attrs) do
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
      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:new_route_form, to_form(changeset, as: :route))
         |> push_event("focus_form_error", %{
           form_id: "new-route-form",
           fallback_id: "new-route-form-error"
         })}
    end
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
end
