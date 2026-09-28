defmodule GtfsPlannerWeb.Gtfs.RoutesLive do
  @moduledoc """
  LiveView for browsing GTFS routes.
  Requires pathways_studio_editor role.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.FeedSettingsComponents,
    only: [agency_form_fields: 1, unsaved_guard: 1]

  import GtfsPlannerWeb.PlannerComponents, only: [constraint_chip: 1, sort_header: 1]

  alias Ecto.Changeset
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Components.RouteIdentity
  alias GtfsPlannerWeb.Gtfs.RouteFormComponents
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The keys stay strings because LiveView params are string-keyed; an atom list
  # would make `Map.take/2` return `%{}`. This is the editor allowlist R1 owns,
  # and it starts with the natural ID because the drawer is the one place that
  # field is creation-legal. Tenant, version, UUID, active and derivation keys
  # are still never read from the browser, and `strip_managed_route_id/2` drops
  # the ID again whenever the drawer has not been overridden, so the command
  # stays the only allocator.
  @new_route_fields ~w(route_id route_short_name route_long_name route_type agency_id route_desc route_url route_color route_text_color)
  @new_route_param_keys @new_route_fields ++ Enum.map(@new_route_fields, &("_unused_" <> &1))

  # A creation attempt is signed once, when the drawer opens, and travels with
  # the form: browser field edits cannot mint a new one, and only the verified
  # payload reaches the domain command (R3). The salt names this purpose, and
  # the age is a bound on a drawer left open rather than a replay window: the
  # attempt's own replay protection is the retained create log (INV-3).
  @creation_attempt_salt "route_creation_attempt"
  @creation_attempt_max_age 14_400

  # Anything the operator typed or chose makes the drawer dirty, so closing it
  # asks once instead of discarding a draft silently (the reference's
  # "Discard this route?"). A preselected agency is not a draft.
  @new_route_draft_fields ~w(route_short_name route_long_name route_desc route_url route_color route_text_color)

  # The agency setup form's id prefixes its field ids, so the drawer's timezone
  # field and the save failure the `FormErrorFocus` hook focuses agree.
  @agency_setup_form_id "routes-agency-form"

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
     |> assign(:new_route_mode_counts, [])
     |> assign(:new_route_attempt, nil)
     |> assign(:new_route_id_mode, :auto)
     |> assign(:new_route_id_suggestion, nil)
     |> assign(:new_route_text_mode, "automatic")
     |> assign(:new_route_dirty?, false)
     |> assign(:new_route_pending?, false)
     |> assign(:new_route_failure, nil)
     |> assign(:new_route_confirm_discard?, false)
     |> assign(:new_route_agency_required?, false)
     |> assign(:agency_health, %{
       agency_count: 0,
       unassigned_routes: 0,
       zone: {:unresolved, :missing}
     })
     |> assign(:agency_setup_form, nil)
     |> assign(:agency_setup_baseline, nil)
     |> assign(:agency_setup_origin, nil)
     |> assign(:agency_setup_opener_id, nil)
     |> assign(:agency_setup_dirty?, false)
     |> assign(:agency_setup_confirm_discard?, false)
     |> assign(:agency_setup_zone_names, [])
     |> stream(:routes, [])
     |> stream(:routes_mobile, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    route_type = parse_route_type(params["route_type"])
    agency_id = parse_string(params["agency_id"])
    # Status presentation follows the same effective predicate as the shared
    # list/count filters (only explicit false is inactive), so an unknown value
    # presents as All statuses instead of drifting from the query.
    active = Gtfs.normalize_route_status_filter(params["active"])
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
      "active" => active
    }

    socket =
      socket
      |> assign(:agency_health, FeedSettings.agency_health(organization_id, gtfs_version_id))
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

    socket =
      assign(socket, :agency_health, FeedSettings.agency_health(organization_id, gtfs_version_id))

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
    if socket.assigns.agency_health.agency_count == 0 do
      # A version with no agency cannot reach route creation, so the header's
      # Create route opens the agency setup instead of an empty route drawer
      # (AC-24). The route drawer opens from that drawer's own save.
      {:noreply, open_agency_setup(socket, :first_route, "new-route-trigger")}
    else
      {:noreply, open_route_drawer(socket)}
    end
  end

  @impl true
  def handle_event("open_agency_setup", params, socket) do
    origin = parse_agency_setup_origin(params["origin"])

    {:noreply, open_agency_setup(socket, origin, params["opener_id"])}
  end

  @impl true
  def handle_event("validate_agency_setup", %{"agency" => params}, socket) do
    if is_nil(socket.assigns.agency_setup_form) do
      {:noreply, socket}
    else
      changeset = FeedSettings.change_agency(socket.assigns.agency_setup_baseline, params)

      {:noreply, assign_agency_setup_draft(socket, changeset, :validate)}
    end
  end

  def handle_event("validate_agency_setup", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_agency_setup", %{"agency" => params}, socket) do
    if is_nil(socket.assigns.agency_setup_form) do
      # A replayed or late submit after the drawer closed must not insert.
      {:noreply, socket}
    else
      create_agency_setup(socket, params)
    end
  end

  def handle_event("save_agency_setup", _params, socket), do: {:noreply, socket}

  # Every route out of the agency drawer — Cancel, the close button and, through
  # the `OverlayDialog` hook's dismiss control, Escape and the backdrop — lands
  # on this event, so a changed draft is asked about exactly once (AC-6).
  @impl true
  def handle_event("close_agency_setup", _params, socket) do
    {:noreply, request_agency_setup_close(socket)}
  end

  @impl true
  def handle_event("cancel_discard_agency_setup", _params, socket) do
    {:noreply, assign(socket, :agency_setup_confirm_discard?, false)}
  end

  @impl true
  def handle_event("confirm_discard_agency_setup", _params, socket) do
    {:noreply, close_agency_setup(socket)}
  end

  @impl true
  def handle_event("validate_new_route", %{"route" => params}, socket) do
    if is_nil(socket.assigns.new_route_form) or socket.assigns.new_route_pending? do
      {:noreply, socket}
    else
      {:noreply, assign_new_route_draft(socket, params, :validate)}
    end
  end

  @impl true
  def handle_event("validate_new_route", _params, socket), do: {:noreply, socket}

  # Cancel, the close button and, through the `OverlayDialog` hook's dismiss
  # control, Escape and the backdrop all land here, so a changed draft is asked
  # about exactly once.
  @impl true
  def handle_event("close_new_route", _params, socket) do
    {:noreply, request_new_route_close(socket)}
  end

  @impl true
  def handle_event("cancel_discard_new_route", _params, socket) do
    {:noreply, assign(socket, :new_route_confirm_discard?, false)}
  end

  @impl true
  def handle_event("confirm_discard_new_route", _params, socket) do
    {:noreply, close_new_route(socket)}
  end

  # "Change" hands the identifier to the editor; the generated value travels
  # into the field so switching back and forth is lossless.
  @impl true
  def handle_event("use_manual_route_id", _params, socket) do
    if is_nil(socket.assigns.new_route_form) or socket.assigns.new_route_id_mode == :manual do
      {:noreply, socket}
    else
      # The form already carries the generated value, so the override field
      # opens on it and switching back is lossless.
      {:noreply,
       socket
       |> assign(:new_route_id_mode, :manual)
       |> push_event("focus_scoped_target", %{id: "new-route-id-manual"})}
    end
  end

  @impl true
  def handle_event("use_generated_route_id", _params, socket) do
    if is_nil(socket.assigns.new_route_form) or socket.assigns.new_route_id_mode == :auto do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:new_route_id_mode, :auto)
       |> apply_generated_route_id()}
    end
  end

  @impl true
  def handle_event("save_new_route", %{"route" => params} = event, socket) do
    cond do
      is_nil(socket.assigns.new_route_form) ->
        # A replayed or late submit after the drawer closed must not insert.
        {:noreply, socket}

      # The reference disables the whole form while a save is in flight, so a
      # double click is one create rather than two.
      socket.assigns.new_route_pending? ->
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
        create_new_route(socket, params, event["text_mode"], event["_attempt"])
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
            variant={
              if(first_use_empty?(assigns) or onboarding?(assigns), do: "secondary", else: "primary")
            }
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

      <div :if={no_agency_routes?(assigns)} id="routes-no-agency" class="mt-6">
        <.callout kind="warning" title="These routes have no agency">
          Set up the agency that operates them. Creating it assigns it to all {@agency_health.unassigned_routes} routes.
          <div class="mt-3">
            <.button
              id="routes-set-up-agency"
              type="button"
              variant="secondary"
              size="sm"
              class="min-h-11"
              phx-click="open_agency_setup"
              phx-value-origin="assign_routes"
              phx-value-opener_id="routes-set-up-agency"
            >
              Set up agency
            </.button>
          </div>
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
                        :if={route.active == false}
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
                      navigate={~p"/gtfs/#{@current_gtfs_version.id}/routes/#{route.route_id}"}
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
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/routes/#{route.route_id}"}
                class="flex min-h-11 items-center gap-3 px-4 py-3 hover:bg-canvas"
              >
                <%!-- A short name can be a sentence; the cap wraps it inside the badge so the
                     route name and chevron stay on the row. --%>
                <RouteIdentity.route_badge
                  route={route}
                  class="min-h-[26px] min-w-[30px] max-w-28 text-center text-[13px] break-words"
                />
                <span class="min-w-0 flex-1">
                  <span class="block truncate text-sm font-[650] text-strong">
                    {route_display_name(route)}
                  </span>
                  <span class="block truncate text-[13px] text-muted">
                    {Route.route_type_label(route.route_type)}
                    <span :if={route.active == false}> · Inactive</span>
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

          <%!-- No agency yet and no routes: the next step is the agency, not a
                 route, so this replaces the first-use empty state. --%>
          <div :if={onboarding?(assigns)} id="routes-agency-onboarding" class="px-5 py-14 sm:px-10">
            <div class="mx-auto max-w-[520px] text-center">
              <p class="text-[13px] font-[650] text-muted">Before your first route</p>
              <h2 class="mt-2 text-[24px]">Who operates this service?</h2>
              <p class="mt-2 text-sm text-muted">
                Journey planners need an agency name, website, and timezone. Set those once, then
                create your first route.
              </p>
              <div class="mt-6 flex flex-wrap justify-center gap-3">
                <.button
                  id="routes-set-up-agency"
                  type="button"
                  class="min-h-11"
                  phx-click="open_agency_setup"
                  phx-value-origin="first_route"
                  phx-value-opener_id="routes-set-up-agency"
                >
                  Set up agency
                </.button>
              </div>
              <p class="mt-3 text-sm">
                <.link
                  id="routes-onboarding-import"
                  navigate={~p"/gtfs/#{@current_gtfs_version.id}/import"}
                  class="text-action hover:underline"
                >
                  Import an existing GTFS feed instead
                </.link>
              </p>
            </div>
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
        attempt={@new_route_attempt}
        agency_options={@agency_options}
        mode_counts={@new_route_mode_counts}
        id_mode={@new_route_id_mode}
        id_suggestion={@new_route_id_suggestion}
        text_mode={@new_route_text_mode}
        dirty?={@new_route_dirty?}
        pending?={@new_route_pending?}
        failure={@new_route_failure}
        agency_required?={@new_route_agency_required?}
        version={@current_gtfs_version}
      />

      <.confirm_dialog
        :if={@new_route_confirm_discard?}
        id="new-route-discard"
        open={true}
        title="Discard this route?"
        confirm_label="Discard route"
        pending_label="Discarding\u2026"
        cancel_label="Keep editing"
        on_confirm="confirm_discard_new_route"
        on_cancel="cancel_discard_new_route"
        described_by="new-route-discard-message"
      >
        <p id="new-route-discard-message">
          You started this route. Nothing has been created yet, and your entries will be lost.
        </p>
      </.confirm_dialog>

      <.agency_setup_drawer
        form={@agency_setup_form}
        opener_id={@agency_setup_opener_id}
        dirty?={@agency_setup_dirty?}
        zone_names={@agency_setup_zone_names}
        version={@current_gtfs_version}
        organization={@current_organization}
      />

      <.confirm_dialog
        :if={@agency_setup_confirm_discard?}
        id="routes-agency-discard"
        open={true}
        title="Discard unsaved changes?"
        confirm_label="Discard changes"
        pending_label="Discarding…"
        cancel_label="Keep editing"
        on_confirm="confirm_discard_agency_setup"
        on_cancel="cancel_discard_agency_setup"
        confirm_variant="danger"
        described_by="routes-agency-discard-body"
      >
        <p>Your entries will be lost. No agency is created.</p>
      </.confirm_dialog>
    </Layouts.app>
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

  # The version's first agency decides its schedule timezone, so this drawer is
  # the create form `AgencyLive` uses with its timezone field: one form for the
  # first agency wherever it is set up (step 17's `agency_form_fields/1`).
  attr :form, :any, default: nil
  attr :opener_id, :string, default: nil
  attr :dirty?, :boolean, default: false
  attr :zone_names, :list, default: []
  attr :version, :any, required: true
  attr :organization, :any, required: true

  defp agency_setup_drawer(assigns) do
    assigns = assign(assigns, :form_id, @agency_setup_form_id)

    ~H"""
    <.drawer
      id="routes-agency-drawer"
      open={not is_nil(@form)}
      on_close="close_agency_setup"
      title="Set up your agency"
      initial_focus={:first_field}
      return_focus_id={@opener_id}
    >
      <:header_actions>
        <span
          :if={@dirty?}
          id="routes-agency-unsaved"
          class="badge badge-warning badge-sm whitespace-nowrap"
        >
          Unsaved changes
        </span>
      </:header_actions>

      <div :if={@form} id="routes-agency-form-panel" phx-hook="FormErrorFocus">
        <.unsaved_guard id="routes-agency-unsaved-guard" dirty={@dirty?} />

        <p id="routes-agency-drawer-scope" class="text-xs text-base-content/70">
          {@version.name} · {@organization.name}
        </p>

        <p class="mt-2 text-sm text-base-content/70">
          Use the public name riders recognize. Optional fields are marked.
        </p>

        <.form
          for={@form}
          id={@form_id}
          novalidate
          phx-change="validate_agency_setup"
          phx-submit="save_agency_setup"
          class="mt-4"
        >
          <.callout
            :if={agency_setup_save_failed?(@form)}
            id="routes-agency-form-error"
            kind="error"
            title="Nothing was created. Check the highlighted fields."
            tabindex="-1"
            class="mb-4"
          />

          <.agency_form_fields form={@form} first_agency?={true} zone_names={@zone_names} />

          <div class="mt-8 flex flex-wrap items-center justify-end gap-3 border-t border-base-300 pt-5">
            <.button
              id="routes-agency-cancel"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="close_agency_setup"
            >
              Cancel
            </.button>

            <.button
              id="routes-agency-save"
              type="submit"
              class="min-h-11"
              phx-disable-with="Creating…"
            >
              Create agency
            </.button>
          </div>
        </.form>
      </div>
    </.drawer>
    """
  end

  attr :form, :any, default: nil
  attr :attempt, :string, default: nil
  attr :agency_options, :list, default: []
  attr :mode_counts, :list, default: []
  attr :id_mode, :atom, default: :auto
  attr :id_suggestion, :any, default: nil
  attr :text_mode, :string, default: nil
  attr :dirty?, :boolean, default: false
  attr :pending?, :boolean, default: false
  attr :failure, :any, default: nil
  attr :agency_required?, :boolean, default: false
  attr :version, :any, required: true

  # The create drawer is the reference's `create-drawer` composed from the
  # shared controls step 18 and step 20 published: the header is the live
  # preview, the body is the shared identity and color grammar, and the
  # identifier block explains the value the command will allocate or takes the
  # operator's override. This LiveView owns the state and the events; the
  # controls stay stateless (INV-6).
  defp new_route_drawer(assigns) do
    assigns =
      assigns
      |> assign(:manual_id?, assigns.id_mode == :manual)
      |> assign(:id_errors, new_route_id_errors(assigns.form))
      |> assign(:preview, new_route_preview(assigns.form, assigns.agency_options))

    ~H"""
    <.drawer
      id="new-route-drawer"
      open={not is_nil(@form)}
      pending={@pending?}
      on_close="close_new_route"
      title="Create route"
      initial_focus={:first_field}
      return_focus_id="new-route-trigger"
      class="max-w-[min(100vw,520px)]"
    >
      <:header_actions>
        <span
          :if={@dirty?}
          id="new-route-unsaved"
          class="badge badge-warning badge-sm whitespace-nowrap"
        >
          Unsaved changes
        </span>
      </:header_actions>

      <div id="new-route-form-panel" phx-hook="FormErrorFocus">
        <p id="new-route-drawer-scope" class="text-[13px] text-muted">
          Adds a route to {@version.name}
        </p>

        <%!-- The header preview: the badge and name as riders will see them,
               computed from this draft alone and never from a saved row. --%>
        <div
          id="new-route-preview"
          class="mt-4 flex min-h-12 items-center gap-3 rounded-control bg-canvas px-3 py-2"
        >
          <RouteIdentity.route_badge
            route={@preview.route}
            class="h-8 min-w-9 text-[15px] font-extrabold"
          />
          <span class="min-w-0 flex-1">
            <span
              id="new-route-preview-name"
              class={[
                "block truncate text-[15px] font-[650]",
                if(@preview.name == "", do: "text-muted", else: "text-strong")
              ]}
            >
              {if(@preview.name == "", do: "Name appears here", else: @preview.name)}
            </span>
            <span id="new-route-preview-meta" class="block text-[13px] text-muted">
              {@preview.meta}
            </span>
          </span>
        </div>

        <div :if={@agency_required?} class="mt-4">
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
              navigate={agencies_path(@version.id)}
              class="mt-2 block font-medium text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
            >
              Open Settings › Agencies
            </.link>
          </.callout>
        </div>

        <.form
          :if={@form}
          for={@form}
          id="new-route-form"
          novalidate
          phx-change="validate_new_route"
          phx-submit="save_new_route"
          class="mt-5 grid gap-6"
        >
          <%!-- One signed attempt per drawer opening, minted by the server and
                verified before the command runs: field edits never mint a new
                one, and the domain never sees a browser-claimed actor (R3). --%>
          <input type="hidden" name="_attempt" id="new-route-attempt" value={@attempt} />

          <div :if={new_route_save_failed?(@form)}>
            <.callout
              id="new-route-form-error"
              kind="error"
              title="Route not created. Check the highlighted fields"
              tabindex="-1"
            >
              Nothing was created. Correct the fields marked below, then create the route again.
            </.callout>
          </div>

          <div :if={@failure} id="new-route-failure" tabindex="-1">
            <.callout kind="error" title="Route not created">
              {@failure.message}
              <.link
                :if={@failure.link}
                id="new-route-failure-link"
                navigate={@failure.link}
                class="mt-2 block font-medium text-primary underline-offset-2 hover:underline"
              >
                Open the route this drawer already created
              </.link>
            </.callout>
          </div>

          <RouteFormComponents.identity_fields
            form={@form}
            prefix="new-route"
            mode_counts={@mode_counts}
            agency_options={@agency_options}
          />

          <RouteFormComponents.color_fields
            form={@form}
            prefix="new-route"
            text_mode={@text_mode}
          />

          <%!-- Natural ID is creation-only (R1): the drawer either shows the
                value the command will allocate, with the reason, or takes an
                override the command rechecks under the version lock. --%>
          <div id="new-route-identity-fields" class="grid gap-1.5 border-t border-subtle pt-5">
            <div class="flex items-center justify-between gap-3">
              <label
                :if={@manual_id?}
                for="new-route-id-manual"
                class="text-[13px] font-[650] text-default"
              >
                Route ID
              </label>
              <p :if={not @manual_id?} class="text-[13px] font-[650] text-default">Route ID</p>
              <button
                :if={not @manual_id?}
                type="button"
                id="new-route-id-edit"
                phx-click="use_manual_route_id"
                class="inline-flex min-h-9 items-center font-[650] text-action underline underline-offset-2 hover:no-underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
              >
                <.icon name="hero-pencil-square" class="mr-1 size-3.5" /> Change
              </button>
              <button
                :if={@manual_id?}
                type="button"
                id="new-route-id-auto"
                phx-click="use_generated_route_id"
                class="inline-flex min-h-9 items-center font-[650] text-action underline underline-offset-2 hover:no-underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
              >
                Use the generated ID
              </button>
            </div>

            <div :if={not @manual_id?} id="new-route-id-generated">
              <p
                id="new-route-id-value"
                class={[
                  "flex min-h-11 items-center rounded-control bg-canvas px-3 font-mono text-sm",
                  if(generated_route_id(@id_suggestion) == "",
                    do: "text-muted",
                    else: "text-strong"
                  )
                ]}
              >
                {generated_route_id(@id_suggestion)}
              </p>
              <p id="new-route-id-reason" class="mt-1.5 text-[13px] text-muted">
                {generated_route_id_reason(@id_suggestion, @preview.mode)}
              </p>
            </div>

            <div :if={@manual_id?} class="grid gap-1.5">
              <input
                type="text"
                id="new-route-id-manual"
                name="route[route_id]"
                value={@form[:route_id].value}
                phx-debounce="blur"
                autocomplete="off"
                spellcheck="false"
                maxlength="255"
                aria-invalid={to_string(@id_errors != [])}
                aria-describedby={
                  if(@id_errors == [],
                    do: "new-route-id-help",
                    else: "new-route-id-error new-route-id-help"
                  )
                }
                class="h-11 max-w-[240px] w-full rounded-control border border-control bg-white px-3 font-mono text-sm text-strong placeholder:text-muted aria-[invalid=true]:border-2 aria-[invalid=true]:border-error-fg"
              />
              <p id="new-route-id-help" class="mt-1.5 text-[13px] text-muted">
                Unique in this version. Trips, transfers and fare rules refer to it, so it can't
                change later.
              </p>
            </div>

            <p
              :if={@id_errors != []}
              id="new-route-id-error"
              class="mt-1.5 flex items-start gap-1.5 text-[13px] font-semibold text-error-fg"
            >
              <.icon name="hero-exclamation-circle" class="mt-px size-3.5 shrink-0" />
              {Enum.join(@id_errors, " ")}
            </p>
          </div>

          <p class="rounded-control bg-canvas px-3 py-2.5 text-[13px] text-muted">
            Add a description, web page and display order on the route's Details tab after you
            create it.
          </p>

          <div class="flex flex-wrap items-center justify-end gap-3">
            <.button
              id="new-route-cancel"
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
              disabled={@pending?}
              phx-disable-with="Creating…"
            >
              Create route
            </.button>
          </div>
        </.form>
      </div>
    </.drawer>
    """
  end

  # The drawer's own live preview, computed from the draft form alone. The badge
  # is the real `RouteIdentity.route_badge/1`, so a draft can never be shown
  # wearing a treatment the list would not draw (INV-6, C-2).
  # The drawer stays in the DOM while it is closed, so the `OverlayDialog` hook
  # keeps its element and the form is simply absent: every draft-derived value
  # is answered for that state too.
  defp new_route_id_errors(nil), do: []
  defp new_route_id_errors(form), do: RouteFormComponents.field_errors(form[:route_id])

  defp new_route_preview(nil, _agency_options), do: new_route_preview_values("", "", "", nil)

  defp new_route_preview(form, agency_options) do
    new_route_preview_values(
      trimmed_field(form[:route_short_name].value),
      trimmed_field(form[:route_long_name].value),
      trimmed_field(form[:route_type].value),
      agency_name_for(agency_options, trimmed_field(form[:agency_id].value)),
      trimmed_field(form[:route_id].value),
      trimmed_field(form[:route_color].value),
      trimmed_field(form[:route_text_color].value)
    )
  end

  defp new_route_preview_values(
         short,
         long,
         mode,
         agency,
         route_id \\ "",
         color \\ "",
         text \\ ""
       ) do
    name =
      cond do
        long != "" -> long
        short != "" -> short
        true -> ""
      end

    mode_label = mode_label_for(mode)
    meta = [mode_label, agency] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")

    %{
      name: name,
      mode: mode_label,
      meta: if(meta == "", do: "Mode not chosen", else: meta),
      # The badge is the real `RouteIdentity.route_badge/1` reading this draft's
      # own colors, so the preview can never wear a treatment the saved row
      # would not draw (INV-6, C-2).
      route: %{
        route_id: route_id,
        route_short_name: short,
        route_color: blank_to(color, "FFFFFF"),
        route_text_color: blank_to(text, "000000")
      }
    }
  end

  defp blank_to(value, default), do: if(value == "", do: default, else: value)

  defp trimmed_field(nil), do: ""
  defp trimmed_field(value) when is_binary(value), do: String.trim(value)
  defp trimmed_field(_value), do: ""

  defp mode_label_for(""), do: "Mode not chosen"

  defp mode_label_for(value) do
    Enum.find_value(Route.route_type_options(), "Mode not chosen", fn {label, mode} ->
      if to_string(mode) == value, do: label
    end)
  end

  defp agency_name_for(_options, ""), do: nil

  defp agency_name_for(options, agency_id) do
    Enum.find_value(options, fn option ->
      if option.agency_id == agency_id, do: option.agency_name
    end)
  end

  # The generated value and the reason the reference states under it, phrased
  # from the inference reason the domain returned rather than recomputed here.
  defp generated_route_id(nil), do: ""

  defp generated_route_id(%{route_id: route_id}) when is_binary(route_id) do
    if String.trim(route_id) == "", do: "", else: String.trim(route_id)
  end

  defp generated_route_id(_suggestion), do: ""

  defp generated_route_id_reason(nil, _mode_label),
    do: "Generated from the route number when you type one."

  defp generated_route_id_reason(%{route_id: ""}, _mode_label),
    do: "Enter a route number or name first."

  defp generated_route_id_reason(%{mode: :manual}, _mode_label), do: "Uses your own route ID."

  defp generated_route_id_reason(%{reason: :inferred_prefix}, mode_label),
    do: "Follows the pattern of this version's other #{String.downcase(mode_label)} routes."

  defp generated_route_id_reason(%{reason: :number}, _mode_label),
    do: "Made from the route number."

  defp generated_route_id_reason(%{reason: :name_slug}, _mode_label),
    do: "Made from the route name."

  defp generated_route_id_reason(_suggestion, _mode_label),
    do: "Made from the route name; this version has no naming pattern to follow."

  defp onboarding?(assigns), do: unconstrained_empty?(assigns) and no_agency?(assigns)

  defp first_use_empty?(assigns), do: unconstrained_empty?(assigns) and not no_agency?(assigns)

  defp unconstrained_empty?(assigns) do
    assigns.routes_state == :ready and assigns.routes_empty? and
      not has_active_constraints?(assigns)
  end

  # A version whose routes carry no agency shows the callout beside the catalog
  # (AC-25); a catalog the filters emptied keeps its own state instead.
  defp no_agency_routes?(assigns) do
    assigns.routes_state == :ready and not assigns.routes_empty? and no_agency?(assigns)
  end

  defp no_agency?(assigns), do: assigns.agency_health.agency_count == 0

  # The first agency the version gets is set up here, whether the editor arrived
  # from the onboarding, the header's Create route or the missing-agency callout.
  # `origin` decides what a saved agency opens next: the New route drawer, or the
  # catalog reloaded with the routes the create just assigned (AC-24, AC-25).
  defp open_agency_setup(socket, origin, opener_id) do
    baseline = %Agency{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id
    }

    socket
    |> assign(:agency_setup_origin, origin)
    |> assign(:agency_setup_opener_id, opener_id)
    |> assign(:agency_setup_baseline, baseline)
    |> assign(:agency_setup_confirm_discard?, false)
    # This is always the version's first agency, so its form carries the schedule
    # timezone field and the datalist that field suggests from (R2, INV-4).
    |> assign(:agency_setup_zone_names, DisplayClock.zone_names())
    |> assign_agency_setup_draft(FeedSettings.change_agency(baseline, %{}))
  end

  # `action: :validate` marks a keystroke, so `used_input?/1` shows an error
  # beside the field the editor has touched and the save-failure callout stays
  # for saves only, the way the Agencies page's create drawer does it.
  defp assign_agency_setup_draft(socket, changeset, action \\ nil) do
    changeset = if action, do: Map.put(changeset, :action, action), else: changeset

    socket
    |> assign(:agency_setup_form, to_form(changeset, as: :agency, id: @agency_setup_form_id))
    |> assign(:agency_setup_dirty?, changeset.changes != %{})
  end

  defp request_agency_setup_close(%{assigns: %{agency_setup_dirty?: true}} = socket),
    do: assign(socket, :agency_setup_confirm_discard?, true)

  defp request_agency_setup_close(socket), do: close_agency_setup(socket)

  defp close_agency_setup(socket) do
    socket
    |> assign(:agency_setup_form, nil)
    |> assign(:agency_setup_baseline, nil)
    |> assign(:agency_setup_origin, nil)
    |> assign(:agency_setup_opener_id, nil)
    |> assign(:agency_setup_dirty?, false)
    |> assign(:agency_setup_confirm_discard?, false)
    |> assign(:agency_setup_zone_names, [])
  end

  # The one write path of the steps 21 drawer: the context authorizes the actor,
  # locks the published version, resolves the zone, chooses the ID and runs the
  # backfill in one transaction (R1, R2, R6, R10, INV-2, INV-5).
  defp create_agency_setup(socket, params) do
    case FeedSettings.create_agency(audit_context(socket), params) do
      {:ok, agency} ->
        {:noreply, finish_agency_setup(socket, agency)}

      {:error, %Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign_agency_setup_draft(changeset)
         |> push_event("focus_form_error", %{
           form_id: @agency_setup_form_id,
           fallback_id: "routes-agency-form-error"
         })}

      # Another editor gave the version agencies with disagreeing zones while this
      # drawer was open, so no single zone can carry this one and nothing was
      # written. The version's own flow resolves that; this drawer cannot.
      {:error, :timezone_unresolved} ->
        {:noreply,
         socket
         |> close_agency_setup()
         |> reload_agency_health()
         |> put_flash(
           :error,
           "This version's agencies no longer share one timezone. Resolve the timezone in Settings › Agencies, then set up this agency."
         )}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> close_agency_setup()
         |> put_flash(:error, "You no longer have editor access to this organization.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> close_agency_setup()
         |> put_flash(:error, "This version is no longer available.")}
    end
  end

  defp finish_agency_setup(socket, agency) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    origin = socket.assigns.agency_setup_origin

    socket =
      socket
      |> close_agency_setup()
      |> reload_agency_health()

    case origin do
      :assign_routes ->
        assigned = assigned_route_count(organization_id, gtfs_version_id, agency.id)

        socket
        |> put_flash(:info, "#{agency.agency_name} created. #{assigned} routes now use it.")
        |> push_patch(
          to:
            ~p"/gtfs/#{gtfs_version_id}/routes?#{build_query_params(socket, socket.assigns.page)}"
        )

      # The version's first agency: the editor's next step is the route it
      # operates, and the drawer opens already set to it (AC-24).
      _first_route ->
        socket
        |> put_flash(:info, "#{agency.agency_name} created.")
        |> open_route_drawer(agency.agency_id)
    end
  end

  defp reload_agency_health(socket) do
    assign(
      socket,
      :agency_health,
      FeedSettings.agency_health(
        socket.assigns.current_organization.id,
        socket.assigns.current_gtfs_version.id
      )
    )
  end

  # "N routes now use it" is read back after the write, so the flash counts the
  # routes the create actually claimed rather than a count from page load (R6).
  defp assigned_route_count(organization_id, gtfs_version_id, agency_id) do
    organization_id
    |> FeedSettings.list_agencies(gtfs_version_id)
    |> Enum.find_value(0, fn
      %{agency: %{id: ^agency_id}, route_count: count} -> count
      _row -> nil
    end)
  end

  defp audit_context(socket) do
    %AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end

  defp parse_agency_setup_origin("assign_routes"), do: :assign_routes
  defp parse_agency_setup_origin(_origin), do: :first_route

  # A failed save is the only state that earns the view-level banner; validation
  # on change marks its own fields and must not shout about a save never attempted.
  defp agency_setup_save_failed?(%Phoenix.HTML.Form{
         source: %Ecto.Changeset{action: action, errors: errors}
       })
       when action in [:insert, :update] and errors != [],
       do: true

  defp agency_setup_save_failed?(_form), do: false

  defp new_route_attrs(_socket, params) do
    # R1's allow-list is the browser boundary: tenant, version, UUID, active,
    # derivation and any unlisted key never reach the command, which takes its
    # scope from the verified attempt and the audit context. `_unused_*` keys
    # are kept for `used_input?/1` and ignored by the changeset.
    Map.take(params, @new_route_param_keys)
  end

  # The New route drawer always reads the version's agencies and modes as they
  # are now. The first-agency handoff names the agency it just created instead
  # of relying on a default derived from a read taken before the create, which
  # is what FH-33 rejects; every other entry derives the default from the fresh
  # read. The identifier preview comes from the same scoped read the command
  # uses, so the drawer never presents a second inference (INV-6).
  defp open_route_drawer(socket, agency_id \\ nil) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    options = Gtfs.route_creation_options(organization_id, gtfs_version_id)

    socket =
      socket
      |> assign(:agency_options, options.agencies)
      |> assign(:new_route_mode_counts, options.mode_counts)
      |> assign(:new_route_attempt, sign_creation_attempt(socket))
      |> assign(:new_route_id_mode, :auto)
      |> assign(:new_route_id_suggestion, nil)
      |> assign(:new_route_text_mode, "automatic")
      |> assign(:new_route_dirty?, false)
      |> assign(:new_route_pending?, false)
      |> assign(:new_route_failure, nil)
      |> assign(:new_route_confirm_discard?, false)
      |> assign(:new_route_agency_required?, false)
      |> assign(:new_route_form, nil)

    attrs = %{"agency_id" => agency_id || default_agency_id(socket, options.agencies)}
    assign_new_route_draft(socket, attrs, nil)
  end

  # The draft's own changeset, in `:create` mode because this drawer is the one
  # place the natural ID is entered: that is the only mode that casts
  # `route_id`, so the shared controls and the override field can show and
  # validate the effective identifier. What the *command* receives is still
  # R1's allowlist, and the identifier is dropped again in automatic mode, so
  # the draft's cast never widens the persisted-field boundary.
  defp new_route_draft_changeset(socket, attrs) do
    Route.editor_changeset(
      %Route{
        organization_id: socket.assigns.current_organization.id,
        gtfs_version_id: socket.assigns.current_gtfs_version.id
      },
      draft_attrs(socket, attrs),
      :create
    )
  end

  defp draft_attrs(socket, attrs) do
    effective = effective_route_id(socket, attrs)

    if effective, do: Map.put(attrs, "route_id", effective), else: attrs
  end

  # In manual mode the operator's own text is the draft's, blank included; in
  # automatic mode the value is whatever the command would allocate.
  defp effective_route_id(socket, attrs) do
    case socket.assigns.new_route_id_mode do
      :manual -> to_string(attrs["route_id"] || "")
      :auto -> socket.assigns.new_route_id_suggestion |> generated_route_id()
    end
  end

  # One draft keystroke: keep the transient text mode, re-read the identifier
  # preview from the domain's own inference, validate what the operator typed
  # with that value in place, and re-evaluate dirtiness.
  defp assign_new_route_draft(socket, params, action) do
    attrs = new_route_attrs(socket, params)
    text_mode = params["text_mode"] || socket.assigns.new_route_text_mode
    socket = assign(socket, :new_route_id_suggestion, suggest_route_id(socket, attrs))

    changeset =
      socket
      |> draft_attrs(attrs)
      |> then(&new_route_draft_changeset(socket, &1))
      |> then(&if action, do: Map.put(&1, :action, action), else: &1)

    socket
    |> assign(:new_route_form, to_form(changeset, as: :route))
    |> assign(:new_route_text_mode, text_mode)
    |> assign(:new_route_dirty?, new_route_dirty?(attrs, text_mode))
  end

  defp new_route_dirty?(attrs, text_mode) do
    text_entered? =
      Enum.any?(@new_route_draft_fields, fn field ->
        String.trim(to_string(attrs[field] || "")) != ""
      end)

    text_entered? or present?(attrs["route_type"]) or present?(attrs["route_id"]) or
      text_mode == "custom"
  end

  # The identifier preview is the automatic inference only: a manual override is
  # never suffixed or renamed, so it is the command that decides whether it is
  # free, and the drawer shows the command's own error when it is not.
  defp suggest_route_id(socket, attrs) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.suggest_route_id(organization_id, gtfs_version_id, Map.delete(attrs, "route_id")) do
      {:ok, allocation} -> allocation
      {:error, :duplicate_route_id} -> nil
    end
  end

  # Leaving manual mode drops the override and re-runs the preview, so the
  # drawer shows the value the command will allocate again.
  defp apply_generated_route_id(socket) do
    form = socket.assigns.new_route_form
    params = Map.delete(form.source.params || %{}, "route_id")
    socket = assign(socket, :new_route_id_suggestion, suggest_route_id(socket, params))

    changeset =
      socket
      |> draft_attrs(params)
      |> then(&new_route_draft_changeset(socket, &1))
      |> Map.put(:action, form.source.action)

    assign(socket, :new_route_form, to_form(changeset, as: :route))
  end

  # The drawer opens with the agency already chosen when the version leaves no
  # real choice: its own only agency, or the agency the catalog is filtered to.
  defp default_agency_id(socket, agency_options) do
    agency_ids = Enum.map(agency_options, & &1.agency_id)
    filtered_id = socket.assigns.filter_form.params["agency_id"]

    cond do
      match?([_], agency_ids) -> hd(agency_ids)
      filtered_id in agency_ids -> filtered_id
      true -> nil
    end
  end

  defp agencies_path(version_id), do: "/gtfs/#{version_id}/settings/agencies"

  # A failed save is the only state that earns the view-level banner; validation
  # on change marks its own fields and must not shout about a save never
  # attempted.
  defp new_route_save_failed?(%Phoenix.HTML.Form{
         source: %Ecto.Changeset{action: action, errors: errors}
       })
       when action in [:insert, :update] and errors != [],
       do: true

  defp new_route_save_failed?(_form), do: false

  defp request_new_route_close(%{assigns: %{new_route_dirty?: true}} = socket),
    do: assign(socket, :new_route_confirm_discard?, true)

  defp request_new_route_close(socket), do: close_new_route(socket)

  defp close_new_route(socket) do
    socket
    |> assign(:new_route_form, nil)
    |> assign(:agency_options, [])
    |> assign(:new_route_mode_counts, [])
    |> assign(:new_route_attempt, nil)
    |> assign(:new_route_id_mode, :auto)
    |> assign(:new_route_id_suggestion, nil)
    |> assign(:new_route_text_mode, "automatic")
    |> assign(:new_route_dirty?, false)
    |> assign(:new_route_pending?, false)
    |> assign(:new_route_failure, nil)
    |> assign(:new_route_confirm_discard?, false)
    |> assign(:new_route_agency_required?, false)
  end

  # One signed attempt per drawer opening (R3). The payload is exactly what the
  # command rechecks, and the signature is what makes the domain's actor
  # trustworthy: a browser-claimed actor cannot reach the mutation, and a field
  # edit cannot mint a fresh attempt.
  defp sign_creation_attempt(socket) do
    Phoenix.Token.sign(GtfsPlannerWeb.Endpoint, @creation_attempt_salt, %{
      creation_attempt_id: Ecto.UUID.generate(),
      actor_id: socket.assigns.current_user.id,
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id
    })
  end

  # A missing, malformed, foreign or expired attempt leaves the draft on screen
  # with no blind save, which is the recovery R3 asks for: check the route list
  # and open a fresh drawer rather than retrying with another suffix.
  defp verify_creation_attempt(nil), do: :error

  defp verify_creation_attempt(token) when is_binary(token) do
    case Phoenix.Token.verify(
           GtfsPlannerWeb.Endpoint,
           @creation_attempt_salt,
           token,
           max_age: @creation_attempt_max_age
         ) do
      {:ok, attempt} -> attempt
      {:error, _reason} -> :error
    end
  end

  defp verify_creation_attempt(_token), do: :error

  # The drawer's one write path (R3): the verified attempt and the audit context
  # reach `Gtfs.create_editor_route/3`, which reauthorizes, locks the published
  # version, resolves the agency, allocates the identifier and writes the route
  # audit in one serializable transaction. Nothing is written by this function.
  defp create_new_route(socket, params, text_mode, token) do
    case verify_creation_attempt(token) do
      :error ->
        {:noreply,
         socket
         |> assign(:new_route_failure, %{
           message:
             "This create attempt is no longer valid, so nothing was created. Check the route list, then choose Create route to start a fresh one.",
           link: nil,
           reason: :invalid_attempt
         })
         |> push_event("focus_scoped_target", %{id: "new-route-failure"})}

      attempt ->
        # The transient text mode is transport metadata R1 lets the changeset
        # pop; the identifier follows the drawer's own override state, so an
        # untouched draft leaves the allocation to the command.
        attrs =
          socket
          |> new_route_attrs(params)
          |> Map.put("text_mode", text_mode)
          |> strip_managed_route_id(socket.assigns.new_route_id_mode)

        run_creation(socket, attrs, attempt)
    end
  end

  defp strip_managed_route_id(attrs, :manual), do: attrs
  defp strip_managed_route_id(attrs, :auto), do: Map.delete(attrs, "route_id")

  @consumed_message "Nothing was created: this drawer already created a route that has since been deleted. Open a fresh Create route to create another."

  @busy_message "Nothing was created and your entries are still here. Choose Create route to try again."

  defp run_creation(socket, attrs, attempt) do
    case Gtfs.create_editor_route(attrs, attempt, audit_context(socket)) do
      {:ok, %{route: route}} ->
        {:noreply, finish_new_route(socket, route)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         # The command rolled the changeset back, so it carries no action; the
         # drawer marks it submitted to decide whether the view-level callout
         # belongs above the fields.
         |> assign(:new_route_form, changeset |> Map.put(:action, :insert) |> to_form(as: :route))
         |> push_event("focus_form_error", %{
           form_id: "new-route-form",
           fallback_id: "new-route-form-error"
         })}

      # A committed create whose result was deleted, or one whose submitted
      # values changed after success, never inserts a second route. The drawer
      # keeps its draft and offers the result the command already holds.
      {:error, :attempt_consumed} ->
        {:noreply, creation_failure(socket, @consumed_message, nil)}

      {:error, {:attempt_mismatch, %{route_id: route_id}}} ->
        {:noreply,
         creation_failure(
           socket,
           "Nothing was created: an earlier save from this drawer already created a route with different values.",
           "/gtfs/#{socket.assigns.current_gtfs_version.id}/routes/#{route_id}"
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> close_new_route()
         |> put_flash(:error, "This version is no longer available.")}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> close_new_route()
         |> put_flash(
           :error,
           "Route not created: you no longer have editor access to this organization."
         )}

      # Busy, failed audit and an unusable request are all "nothing was
      # written, the draft is still here": the mutation and its audit commit
      # together, so no partial create can be left behind.
      {:error, reason} ->
        {:noreply, creation_failure(socket, @busy_message, nil, reason)}
    end
  end

  defp creation_failure(socket, message, link, reason \\ nil) do
    socket
    |> assign(:new_route_failure, %{message: message, link: link, reason: reason})
    |> push_event("focus_scoped_target", %{id: "new-route-failure"})
  end

  # A created route opens its own Details, because the next step is the stops
  # it serves (AC-7). The flash names the identifier the command actually
  # allocated, which is the truth the drawer's preview could not promise while
  # the allocation was still only a preview (INV-6).
  defp finish_new_route(socket, route) do
    socket
    |> close_new_route()
    |> put_flash(:info, "Route #{route.route_id} created. Next, add the stops it serves.")
    |> push_navigate(to: new_route_details_path(socket, route))
  end

  defp new_route_details_path(socket, route) do
    "/gtfs/#{socket.assigns.current_gtfs_version.id}/routes/#{route.route_id}?created=1"
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
end
