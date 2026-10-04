defmodule GtfsPlannerWeb.Gtfs.StopsLive do
  @moduledoc """
  LiveView for browsing GTFS stops and stations.
  Requires pathways_studio_editor role.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.PlannerComponents,
    only: [constraint_chip: 1, first_use: 1, message: 1, sort_header: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopSelection
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.Components.RouteIdentity
  alias GtfsPlannerWeb.Gtfs.StopTextHelperComponents
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # Constraints a chip can dismiss, by query param.
  @filter_keys ~w(search route_id direction_id wheelchair_boarding)

  # The approved stop set the text helper works inside (spec AC-14); the same
  # ceiling `StopSelection` puts on the lines of one Find.
  @max_stop_set 100

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Stops & stations")
     |> assign(:user_roles, user_roles)
     |> assign(
       :filter_form,
       to_form(%{"wheelchair_boarding" => "", "route_id" => "", "direction_id" => ""})
     )
     |> assign(:search_form, to_form(%{"search" => ""}))
     |> assign(:search, "")
     |> assign(:sort_by, :stop_name)
     |> assign(:sort_dir, :asc)
     |> assign(:page, 1)
     |> assign(:per_page, 50)
     |> assign(:total_count, 0)
     |> assign(:stops_empty?, false)
     |> assign(:stops_state, :loading)
     |> assign(:available_routes, [])
     |> assign(:route_options_state, :not_loaded)
     |> assign(:route_id, nil)
     |> assign(:direction_id, nil)
     |> assign(:canonical_patch_identity, nil)
     |> assign(:skeleton_widths, [46, 38, 52, 34, 44, 40, 46, 38, 52])
     |> assign(:stop_set_open?, false)
     |> assign(:stop_set_form, stop_set_form(""))
     |> assign(:stop_set_error, nil)
     |> assign(:stop_set_notice, nil)
     |> assign(:stop_set_resolution, nil)
     |> assign(:stop_set, nil)
     |> stream(:stops, [])
     |> stream(:stops_mobile, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    params = valid_params(params)

    wheelchair_boarding = parse_wheelchair(params["wheelchair_boarding"])
    route_id = params["route_id"] || ""
    direction_id = parse_direction(params["direction_id"])
    search = params["search"] || ""
    sort_by = parse_column_atom(params["sort_by"]) || :stop_name
    sort_dir = parse_sort_dir(params["sort_dir"])
    page = Values.positive_integer(params["page"], 1)
    per_page = socket.assigns.per_page

    opts = [
      wheelchair_boarding: wheelchair_boarding,
      route_id: route_id,
      direction_id: direction_id,
      search: search,
      sort_by: sort_by,
      sort_dir: sort_dir,
      page: page,
      per_page: per_page
    ]

    filter_form =
      to_form(%{
        "wheelchair_boarding" => params["wheelchair_boarding"] || "",
        "route_id" => route_id,
        "direction_id" => params["direction_id"] || ""
      })

    socket =
      socket
      |> assign(:filter_form, filter_form)
      |> assign(:search_form, to_form(%{"search" => search}))
      |> assign(:search, search)
      |> assign(:sort_by, sort_by)
      |> assign(:sort_dir, sort_dir)
      |> assign(:page, page)
      |> assign(:route_id, route_id)
      |> assign(:direction_id, direction_id)

    canonical_patch_identity = {gtfs_version_id, opts}

    cond do
      not connected?(socket) ->
        {:noreply, socket}

      socket.assigns.canonical_patch_identity == canonical_patch_identity ->
        {:noreply, assign(socket, :canonical_patch_identity, nil)}

      true ->
        socket = load_route_options(socket, organization_id, gtfs_version_id)

        organization_id
        |> Gtfs.load_stop_catalog(gtfs_version_id, opts)
        |> apply_catalog_result(socket, opts)
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/stops")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/stops")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("stop_set_toggle", _params, socket) do
    {:noreply, update(socket, :stop_set_open?, &(not &1))}
  end

  # Editing the text drops the resolution (it describes other text) but never the
  # approved set. A change event that leaves the text as it was changes nothing.
  @impl true
  def handle_event("stop_set_change", %{"stop_set" => %{"refs" => text}}, socket)
      when is_binary(text) do
    if text == socket.assigns.stop_set_form.params["refs"] do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:stop_set_form, stop_set_form(text))
       |> assign(:stop_set_error, nil)
       |> assign(:stop_set_notice, nil)
       |> assign(:stop_set_resolution, nil)}
    end
  end

  def handle_event("stop_set_change", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("stop_set_find", %{"stop_set" => %{"refs" => text}}, socket)
      when is_binary(text) do
    lines = String.split(text, ~r/\R/)

    socket =
      socket
      |> assign(:stop_set_open?, true)
      |> assign(:stop_set_form, stop_set_form(text))
      |> assign(:stop_set_notice, nil)

    result =
      if Enum.all?(lines, &(String.trim(&1) == "")),
        do: {:error, :empty},
        else:
          StopSelection.resolve(
            socket.assigns.current_organization.id,
            socket.assigns.current_gtfs_version.id,
            lines
          )

    case result do
      {:ok, resolution} ->
        {:noreply,
         socket
         |> assign(:stop_set_error, nil)
         |> assign(:stop_set_resolution, Map.put(resolution, :choices, %{}))
         |> push_event("focus_scoped_target", %{id: "stop-set-resolution-heading"})}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:stop_set_error, stop_set_error_text(reason))
         |> assign(:stop_set_resolution, nil)
         |> push_event("focus_form_error", %{form_id: "stop-set-form"})}
    end
  end

  def handle_event("stop_set_find", _params, socket), do: {:noreply, socket}

  # A choice names a candidate by its GTFS stop ID and an ambiguity by its position;
  # both are checked against the resolution this view holds, so a forged value
  # selects nothing.
  @impl true
  def handle_event("stop_set_choose", %{"ref" => index, "stop" => stop_id}, socket)
      when is_binary(index) and is_binary(stop_id) do
    case ambiguity_at(socket.assigns.stop_set_resolution, index) do
      %{ref: ref, candidates: candidates} ->
        if Enum.any?(candidates, &(&1.stop_id == stop_id)),
          do: {:noreply, put_stop_set_choice(socket, ref, stop_id)},
          else: {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("stop_set_choose", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("stop_set_skip", %{"ref" => index}, socket) when is_binary(index) do
    case ambiguity_at(socket.assigns.stop_set_resolution, index) do
      %{ref: ref} -> {:noreply, put_stop_set_choice(socket, ref, :skip)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("stop_set_skip", _params, socket), do: {:noreply, socket}

  # The set is built from the held resolution only, then each stop is read again in
  # this organization and version, so a stop deleted since the Find is refused.
  @impl true
  def handle_event("stop_set_approve", _params, %{assigns: %{stop_set_resolution: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("stop_set_approve", _params, socket) do
    resolution = socket.assigns.stop_set_resolution
    undecided = Enum.count(resolution.ambiguous, &(not Map.has_key?(resolution.choices, &1.ref)))
    selected = selected_stops(resolution)

    cond do
      undecided > 0 ->
        {:noreply,
         refuse_stop_set(
           socket,
           "Choose a stop or skip #{Wording.count_noun(undecided, "line")} first."
         )}

      selected == [] ->
        {:noreply, refuse_stop_set(socket, "No stop is selected.")}

      length(selected) > @max_stop_set ->
        {:noreply, refuse_stop_set(socket, "Approve up to #{@max_stop_set} stops at a time.")}

      true ->
        approve_stop_set(socket, selected)
    end
  end

  @impl true
  def handle_event("stop_set_clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:stop_set, nil)
     |> assign(:stop_set_resolution, nil)
     |> assign(:stop_set_notice, nil)
     |> push_event("focus_scoped_target", %{id: "stop-set-toggle"})}
  end

  @impl true
  def handle_event("filter", params, socket) do
    wheelchair_boarding = params["wheelchair_boarding"]
    route_id = params["route_id"]

    # A direction only means something within a route, so choosing another
    # route, or none, starts again at "All directions".
    direction_id =
      if (route_id || "") == socket.assigns.route_id, do: params["direction_id"]

    query_params =
      %{}
      |> Values.put_present("wheelchair_boarding", wheelchair_boarding)
      |> Values.put_present("route_id", route_id)
      |> Values.put_present("direction_id", direction_id)
      |> Values.put_present("search", socket.assigns.search)
      |> maybe_put_sort(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{query_params}"
     )}
  end

  @impl true
  def handle_event("search", %{"search" => term}, socket) do
    query_params =
      %{}
      |> Values.put_present("search", term)
      |> Values.put_present(
        "wheelchair_boarding",
        socket.assigns.filter_form.params["wheelchair_boarding"]
      )
      |> Values.put_present("route_id", socket.assigns.filter_form.params["route_id"])
      |> Values.put_present("direction_id", socket.assigns.filter_form.params["direction_id"])
      |> maybe_put_sort(socket.assigns.sort_by, socket.assigns.sort_dir)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{query_params}"
     )}
  end

  @impl true
  def handle_event("remove_filter", %{"key" => key}, socket) when key in @filter_keys do
    # Dropping the route drops its direction too, for the reason above.
    dropped = if key == "route_id", do: [key, "direction_id"], else: [key]

    query_params =
      %{}
      |> Values.put_present(
        "wheelchair_boarding",
        socket.assigns.filter_form.params["wheelchair_boarding"]
      )
      |> Values.put_present("route_id", socket.assigns.filter_form.params["route_id"])
      |> Values.put_present("direction_id", socket.assigns.filter_form.params["direction_id"])
      |> Values.put_present("search", socket.assigns.search)
      |> maybe_put_sort(socket.assigns.sort_by, socket.assigns.sort_dir)
      |> Map.drop(dropped)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{query_params}"
     )}
  end

  @impl true
  def handle_event("remove_filter", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("sort", %{"key" => column}, socket) do
    column_atom = parse_column_atom(column)
    current_sort_by = socket.assigns.sort_by
    current_sort_dir = socket.assigns.sort_dir

    {new_sort_by, new_sort_dir} =
      if column_atom == current_sort_by do
        case current_sort_dir do
          :asc -> {current_sort_by, :desc}
          :desc -> {:stop_name, :asc}
        end
      else
        {column_atom, :asc}
      end

    query_params =
      %{}
      |> Values.put_present(
        "wheelchair_boarding",
        socket.assigns.filter_form.params["wheelchair_boarding"]
      )
      |> Values.put_present("route_id", socket.assigns.filter_form.params["route_id"])
      |> Values.put_present("direction_id", socket.assigns.filter_form.params["direction_id"])
      |> Values.put_present("search", socket.assigns.search)
      |> maybe_put_sort(new_sort_by, new_sort_dir)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{query_params}"
     )}
  end

  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    page_num = Values.positive_integer(page, 1)
    query_params = build_query_params(socket, page_num)

    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{query_params}"
     )}
  end

  @impl true
  def handle_event("retry", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    opts = [
      wheelchair_boarding:
        parse_wheelchair(socket.assigns.filter_form.params["wheelchair_boarding"]),
      route_id: socket.assigns.filter_form.params["route_id"] || "",
      direction_id: parse_direction(socket.assigns.filter_form.params["direction_id"]),
      search: socket.assigns.search,
      sort_by: socket.assigns.sort_by,
      sort_dir: socket.assigns.sort_dir,
      page: socket.assigns.page,
      per_page: socket.assigns.per_page
    ]

    socket = load_route_options(socket, organization_id, gtfs_version_id)

    case Gtfs.load_stop_catalog(organization_id, gtfs_version_id, opts) do
      {:ok,
       %{
         rows: stops,
         total_count: total_count,
         page: canonical_page,
         routes_by_stop: routes_by_stop
       }} ->
        stops_with_routes =
          Enum.map(stops, fn s ->
            Map.put(s, :routes, Map.get(routes_by_stop, s.stop_id, []))
          end)

        {:noreply,
         socket
         |> assign(:page, canonical_page)
         |> assign(:total_count, total_count)
         |> assign(:stops_empty?, stops == [])
         |> assign(:stops_state, :ready)
         |> put_stops(stops_with_routes)}

      {:partial,
       %{
         rows: stops,
         total_count: total_count,
         page: canonical_page
       }, :route_enrichment_unavailable} ->
        stops_with_empty_routes =
          Enum.map(stops, fn s -> Map.put(s, :routes, []) end)

        {:noreply,
         socket
         |> assign(:page, canonical_page)
         |> assign(:total_count, total_count)
         |> assign(:stops_empty?, stops == [])
         |> assign(:stops_state, :route_enrichment_unavailable)
         |> put_stops(stops_with_empty_routes)}

      {:error, :unavailable} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops"
     )}
  end

  defp stop_set_form(text), do: to_form(%{"refs" => text}, as: :stop_set)

  defp stop_set_error_text(:empty), do: "Enter at least one stop ID, code or name."
  defp stop_set_error_text(:too_many), do: "Enter up to #{@max_stop_set} lines, one stop each."
  defp stop_set_error_text(:invalid_input), do: "Keep each line to 200 characters or fewer."

  defp ambiguity_at(%{ambiguous: ambiguous}, index) do
    case Integer.parse(index) do
      {position, ""} when position >= 0 -> Enum.at(ambiguous, position)
      _other -> nil
    end
  end

  defp ambiguity_at(nil, _index), do: nil

  defp put_stop_set_choice(socket, ref, choice) do
    update(socket, :stop_set_resolution, fn resolution ->
      %{resolution | choices: Map.put(resolution.choices, ref, choice)}
    end)
  end

  # Resolved matches plus the chosen candidates, each stop once, in stop ID order.
  defp selected_stops(%{resolved: resolved, ambiguous: ambiguous, choices: choices}) do
    chosen =
      Enum.flat_map(ambiguous, fn %{ref: ref, candidates: candidates} ->
        case Map.get(choices, ref) do
          stop_id when is_binary(stop_id) -> Enum.filter(candidates, &(&1.stop_id == stop_id))
          _skipped_or_open -> []
        end
      end)

    (Enum.map(resolved, & &1.stop) ++ chosen)
    |> Enum.uniq_by(& &1.uuid)
    |> Enum.sort_by(& &1.stop_id)
  end

  defp approve_stop_set(socket, selected) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    # Up to 100 point reads on a rare action; one `IN` query is the upgrade path.
    current = Enum.map(selected, &Gtfs.get_stop_by_id(organization_id, gtfs_version_id, &1.uuid))

    if Enum.any?(current, &is_nil/1) do
      {:noreply,
       socket
       |> assign(:stop_set_resolution, nil)
       |> refuse_stop_set("A selected stop no longer exists. Find stops again.")}
    else
      stops =
        current
        |> Enum.map(&%{uuid: &1.id, stop_id: &1.stop_id, stop_name: &1.stop_name})
        |> Enum.sort_by(& &1.stop_id)

      {:noreply,
       socket
       |> assign(:stop_set, stops)
       |> assign(:stop_set_resolution, nil)
       |> assign(:stop_set_notice, nil)
       |> push_event("focus_scoped_target", %{id: "stop-set-summary"})}
    end
  end

  defp refuse_stop_set(socket, message) do
    socket
    |> assign(:stop_set_notice, message)
    |> push_event("focus_scoped_target", %{id: "stop-set-notice"})
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
      <div id="stops-page" class="ds-page">
        <.header>
          Stops &amp; stations
          <:subtitle>
            Find any stop or station in {@current_gtfs_version.name}, see which routes serve it, and check
            wheelchair access.
          </:subtitle>
          <:actions>
            <%!-- The two views are two routes of one page, so the switch is two links
                   and either works without JavaScript. `aria-current="page"` names
                   the view being looked at. --%>
            <div
              id="stops-view-switch"
              class="flex rounded-control border border-control"
              role="group"
              aria-label="View"
            >
              <span
                id="stops-view-list"
                aria-current="page"
                class="flex min-h-11 items-center gap-2 rounded-l-control bg-selection px-4 text-sm font-bold text-action"
              >
                <.icon name="hero-list-bullet" class="size-4" /> List
              </span>
              <.link
                id="stops-view-map"
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/stops/map"}
                class="flex min-h-11 items-center gap-2 rounded-r-control border-l border-control px-4 text-sm font-semibold text-strong no-underline hover:bg-canvas"
              >
                <.icon name="hero-map" class="size-4" /> Map
              </.link>
            </div>

            <.button
              id="stops-add-stop"
              navigate={~p"/gtfs/#{@current_gtfs_version.id}/stops/map?add=1"}
              class="min-h-11"
            >
              <.icon name="hero-plus" class="size-4" /> Add stop
            </.button>
          </:actions>
        </.header>

        <p id="stops-add-stop-note" class="-mt-2 mb-6 text-[13px] text-muted">
          Add stop opens the map, because a stop's place on the street is the first thing to get
          right.
        </p>

        <StopTextHelperComponents.stop_set_section
          :if={not first_use_empty?(assigns)}
          open?={@stop_set_open?}
          form={@stop_set_form}
          error={@stop_set_error}
          notice={@stop_set_notice}
          resolution={@stop_set_resolution}
          stop_set={@stop_set}
        />

        <%!-- Route lookup failed: the stops still load, so the warning sits above
               the card and names what is off. --%>
        <div
          :if={@stops_state == :route_enrichment_unavailable or @route_options_state == :unavailable}
          id="stops-enrichment-warning"
          class="mb-6"
        >
          <.message kind="warning" title="Route information is unavailable">
            <%= if @stops_state == :route_enrichment_unavailable do %>
              Stops are listed without their routes, and the route filter is off. Search and the other
              filters still work.
            <% else %>
              The route filter is off. Search and the other filters still work.
            <% end %>
            <:action>
              <.button
                id="stops-enrichment-retry"
                type="button"
                variant="secondary"
                class="min-h-11"
                phx-click="retry"
                phx-disable-with="Reloading…"
              >
                <.icon name="hero-arrow-path" class="size-4" /> Reload routes
              </.button>
            </:action>
          </.message>
        </div>

        <%!-- Nothing in the version, nothing searched: the toolbar would have
               nothing to act on, so the next step replaces the card. --%>
        <.first_use
          :if={first_use_empty?(assigns)}
          id="stops-first-use-empty"
          title="No stops in this version yet"
        >
          Stops appear here after you import a GTFS feed into {@current_gtfs_version.name}.
          <:action>
            <%!-- One primary per view: Add stop is the filled button and Import
                   feed sits under it, outlined. --%>
            <div class="flex flex-col items-center gap-3">
              <.button
                id="stops-first-use-add-stop"
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/stops/map?add=1"}
                class="min-h-11"
              >
                <.icon name="hero-plus" class="size-4" /> Add stop
              </.button>
              <.button
                id="stops-first-use-import"
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/import"}
                variant="secondary"
                class="min-h-11"
              >
                <.icon name="hero-arrow-up-tray" class="size-4" /> Import feed
              </.button>
            </div>
          </:action>
        </.first_use>

        <section
          :if={not first_use_empty?(assigns)}
          id="stops-workbench"
          aria-label="Stops and stations"
          class="overflow-clip rounded-card border border-subtle bg-white"
        >
          <%!-- Search is used on almost every visit, so it takes the width; the
                 selects less often. The two server forms keep the IDs the tests
                 reach for. --%>
          <div
            id="stops-toolbar"
            role="search"
            class="flex flex-wrap items-end gap-3 border-b border-subtle px-4 py-4 md:px-5"
          >
            <div class="min-w-0 flex-1 basis-[190px] md:basis-[280px]">
              <.form for={@search_form} id="stop-search-form" phx-change="search">
                <.input
                  field={@search_form[:search]}
                  type="search"
                  label="Search stops and stations"
                  placeholder="Stop name or ID"
                  autocomplete="off"
                  phx-debounce="300"
                  disabled={@stops_state == :loading}
                />
              </.form>
            </div>

            <.form
              for={@filter_form}
              id="stop-filter-form"
              phx-change="filter"
              class="flex w-full flex-wrap items-end gap-3 max-md:order-last md:w-auto"
            >
              <div class="min-w-0 flex-1 basis-[140px] md:w-[200px] md:flex-none">
                <.input
                  field={@filter_form[:route_id]}
                  type="select"
                  label="Route"
                  prompt="All routes"
                  disabled={route_filter_disabled?(assigns)}
                  options={route_options(@available_routes, @route_id)}
                />
              </div>
              <div
                :if={@route_id not in [nil, ""]}
                class="min-w-0 flex-1 basis-[140px] md:w-[168px] md:flex-none"
              >
                <.input
                  field={@filter_form[:direction_id]}
                  type="select"
                  label="Direction"
                  prompt="All directions"
                  disabled={@stops_state == :loading}
                  options={[{Trip.direction_label(0), 0}, {Trip.direction_label(1), 1}]}
                />
              </div>
              <div class="min-w-0 flex-1 basis-[140px] md:w-[184px] md:flex-none">
                <.input
                  field={@filter_form[:wheelchair_boarding]}
                  type="select"
                  label="Wheelchair access"
                  prompt="All stops"
                  disabled={@stops_state == :loading}
                  options={[{"Accessible", 1}, {"Not accessible", 2}, {"Not recorded", 0}]}
                />
              </div>
            </.form>
          </div>

          <%!-- The catalog read failed: the toolbar stays so the search and filters
                 are visibly kept, and only the results give way to the error. --%>
          <div :if={@stops_state == :unavailable} id="stops-unavailable" class="p-4 md:p-5">
            <.message kind="error" title="Stops could not load">
              The stop catalog did not respond. Your search and filters are kept. Reload to try again.
              <:action>
                <.button
                  id="stops-retry"
                  type="button"
                  variant="secondary"
                  class="min-h-11"
                  phx-click="retry"
                  phx-disable-with="Reloading…"
                >
                  <.icon name="hero-arrow-path" class="size-4" /> Reload stops
                </.button>
              </:action>
            </.message>
          </div>

          <%!-- Result count and active constraints; each constraint can be removed
                 on its own. --%>
          <div
            :if={@stops_state != :unavailable}
            id="stops-summary"
            class="flex min-h-[52px] flex-wrap items-center gap-x-3 gap-y-1 border-b border-subtle px-4 py-1 text-[13px] md:px-5"
          >
            <p
              :if={@stops_state == :loading}
              id="stops-loading"
              role="status"
              aria-live="polite"
              aria-busy="true"
              class="font-[650] text-strong"
            >
              Loading stops…
            </p>
            <p
              :if={@stops_state != :loading}
              id="stops-count"
              role="status"
              class="font-[650] tabular-nums text-strong"
            >
              {case has_active_constraints?(assigns) do
                true ->
                  Wording.count_noun(
                    @total_count,
                    "stop or station matches",
                    "stops and stations match"
                  )

                false ->
                  Wording.count_noun(@total_count, "stop or station", "stops and stations")
              end}
            </p>

            <div id="stops-chips" class="flex flex-wrap items-center gap-2">
              <.constraint_chip
                :for={filter <- active_filters(assigns)}
                id={"stops-chip-#{filter.key}"}
                key={filter.key}
                kind={filter.kind}
                label={filter.value}
                disabled={@stops_state == :loading}
              />
            </div>

            <button
              :if={
                @stops_state != :loading and has_active_constraints?(assigns) and not @stops_empty?
              }
              id="stops-clear-filters"
              type="button"
              phx-click="clear_filters"
              class="ml-auto inline-flex min-h-11 items-center font-[650] text-action hover:underline"
            >
              {if only_search_active?(assigns), do: "Clear search", else: "Clear filters"}
            </button>
          </div>

          <div :if={@stops_state != :unavailable} id="stops-results">
            <%!-- Desktop and tablet: semantic table. Loading keeps the finished
                   layout, with placeholder rows where the stops will be. --%>
            <div :if={results_visible?(assigns)} id="stops-container" class="max-md:hidden">
              <table class="workbench-table ds-stack-table w-full table-fixed">
                <caption class="sr-only">
                  Stops and stations in {@current_gtfs_version.name}
                </caption>
                <thead>
                  <tr>
                    <.sort_header
                      label="Name"
                      sort_key="stop_name"
                      sort_by={@sort_by}
                      sort_dir={@sort_dir}
                      disabled={@stops_state == :loading}
                    />
                    <.sort_header
                      label="Stop ID"
                      sort_key="stop_id"
                      sort_by={@sort_by}
                      sort_dir={@sort_dir}
                      disabled={@stops_state == :loading}
                      class="w-[128px]"
                    />
                    <.sort_header
                      label="Type"
                      sort_key="location_type"
                      sort_by={@sort_by}
                      sort_dir={@sort_dir}
                      disabled={@stops_state == :loading}
                      class="hidden w-[148px] lg:table-cell"
                    />
                    <th
                      scope="col"
                      class="sticky top-0 z-10 w-[200px] border-b border-subtle bg-canvas text-[13px] font-[650] text-default"
                    >
                      Routes
                    </th>
                    <th
                      scope="col"
                      class="sticky top-0 z-10 w-[176px] border-b border-subtle bg-canvas text-[13px] font-[650] text-default"
                    >
                      Wheelchair access
                    </th>
                  </tr>
                </thead>
                <tbody id="stops" phx-update="stream">
                  <tr
                    :for={{id, stop} <- @streams.stops}
                    id={id}
                    class="relative cursor-pointer hover:bg-canvas/70"
                  >
                    <th scope="row">
                      <.stop_link stop={stop} version_id={@current_gtfs_version.id} />
                    </th>
                    <td class="truncate font-mono text-[13px] tabular-nums text-default">
                      {stop.stop_id}
                    </td>
                    <td class="hidden truncate text-default lg:table-cell">
                      {Stop.location_type_label(stop.location_type)}
                    </td>
                    <td>
                      <.stop_routes routes={stop.routes} state={@stops_state} />
                    </td>
                    <td>
                      <.wheelchair_access status={accessibility_status(stop)} />
                    </td>
                  </tr>
                </tbody>
                <tbody :if={@stops_state == :loading} id="stops-skeleton" aria-hidden="true">
                  <tr :for={width <- @skeleton_widths}>
                    <td class="h-[52px]">
                      <span
                        class="block h-3.5 rounded-badge bg-navy-100/60 motion-safe:animate-pulse"
                        style={"width: #{width}%"}
                      >
                      </span>
                    </td>
                    <td>
                      <span class="block h-3.5 w-14 rounded-badge bg-navy-100/60 motion-safe:animate-pulse">
                      </span>
                    </td>
                    <td class="hidden lg:table-cell">
                      <span class="block h-3.5 w-16 rounded-badge bg-navy-100/60 motion-safe:animate-pulse">
                      </span>
                    </td>
                    <td>
                      <span class="block h-[26px] w-16 rounded-badge bg-navy-100/60 motion-safe:animate-pulse">
                      </span>
                    </td>
                    <td>
                      <span class="block h-3.5 w-24 rounded-badge bg-navy-100/60 motion-safe:animate-pulse">
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <%!-- Phones: one list item per stop, and the whole item is the link. --%>
            <ul
              :if={results_visible?(assigns)}
              id="stops-list"
              phx-update="stream"
              class="workbench-list md:hidden"
            >
              <li :for={{id, stop} <- @streams.stops_mobile} id={id}>
                <.link
                  navigate={~p"/gtfs/#{@current_gtfs_version.id}/stops/#{stop.stop_id}"}
                  class="block min-h-11 px-4 py-3 hover:bg-canvas"
                >
                  <span class="block truncate text-[15px] font-[650] text-strong">
                    {stop_display_name(stop)}
                  </span>
                  <span class="block truncate text-[13px] text-muted">{stop_meta(stop)}</span>
                  <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1.5 text-[13px]">
                    <.stop_routes routes={stop.routes} state={@stops_state} />
                    <.wheelchair_access status={accessibility_status(stop)} />
                  </div>
                </.link>
              </li>
            </ul>

            <div
              :if={@stops_state == :loading}
              id="stops-skeleton-list"
              aria-hidden="true"
              class="workbench-list md:hidden"
            >
              <div :for={width <- @skeleton_widths} class="px-4 py-3">
                <span
                  class="block h-4 rounded-badge bg-navy-100/60 motion-safe:animate-pulse"
                  style={"width: #{width}%"}
                >
                </span>
                <span class="mt-2 block h-3.5 w-24 rounded-badge bg-navy-100/60 motion-safe:animate-pulse">
                </span>
                <span class="mt-3 block h-[26px] w-16 rounded-badge bg-navy-100/60 motion-safe:animate-pulse">
                </span>
              </div>
            </div>

            <%!-- Search or filters exclude every stop. --%>
            <div
              :if={constrained_empty?(assigns)}
              id="stops-constrained-empty"
              class="px-5 py-12 text-center"
            >
              <h2 class="font-sans text-base font-bold tracking-normal text-strong">
                {no_match_title(assigns)}
              </h2>
              <p class="mx-auto mt-1.5 max-w-[46ch] text-sm text-muted">
                {no_match_hint(assigns)}
              </p>
              <button
                id="stops-clear-filters"
                type="button"
                phx-click="clear_filters"
                class="mt-5 inline-flex min-h-11 items-center justify-center rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas"
              >
                {if only_search_active?(assigns), do: "Clear search", else: "Clear filters"}
              </button>
            </div>
          </div>

          <div
            :if={@stops_state != :unavailable and (@stops_state == :loading or @total_count > 0)}
            class="border-t border-subtle px-4 md:px-5"
          >
            <.pagination
              page={@page}
              per_page={@per_page}
              total={@total_count}
              entity="stops & stations"
              disabled={@stops_state == :loading}
            />
          </div>
        </section>

        <%!-- For anyone who exports the feed or troubleshoots it: how the words on
               this page map to the GTFS fields. --%>
        <details
          id="stops-technical-details"
          class="group mt-6 rounded-card border border-subtle bg-white"
        >
          <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 px-4 text-sm font-[650] text-strong hover:bg-canvas [&::-webkit-details-marker]:hidden">
            <.icon
              name="hero-chevron-right"
              class="size-4 text-muted transition-transform group-open:rotate-90"
            /> Technical details for exports and troubleshooting
          </summary>
          <div class="grid gap-x-8 gap-y-2 border-t border-subtle px-4 py-4 text-[13px] text-muted md:grid-cols-2 md:px-5">
            <p>
              This list shows every stop and station that has no parent station (GTFS <code class="font-mono text-default">stops.txt</code>).
            </p>
            <p>
              <strong class="font-[650] text-default">Type</strong>
              is <code class="font-mono text-default">location_type</code>: Stop/Platform is 0, Station is 1.
              <strong class="font-[650] text-default">Wheelchair access</strong>
              is <code class="font-mono text-default">wheelchair_boarding</code>: 1 accessible, 2 not accessible, 0 or blank not recorded.
            </p>
            <p>
              <strong class="font-[650] text-default">Direction</strong>
              is <code class="font-mono text-default">direction_id</code>
              on trips: outbound is 0 and inbound is 1.
            </p>
            <p>
              <strong class="font-[650] text-default">Stop ID</strong>
              is <code class="font-mono text-default">stop_id</code>, the value other systems use to match a stop. Search finds names and IDs.
            </p>
          </div>
        </details>
      </div>
    </Layouts.app>
    """
  end

  # ── Workbench pieces ────────────────────────────────────────────────────────
  #
  # The same card the routes list uses (search and filters, a count with
  # removable constraints, the table, paging), following the design system's
  # `.workbench`. The card's markup stays in `render/1` so each part reads the
  # same assigns; the pieces below repeat inside rows or chips.

  # The stop's name is the link and the whole row is its target (the link's
  # pseudo-element covers the row). The description sits inside the link, so
  # the two stops a street has on opposite sides read as different links.
  # Below `lg` the Type column is hidden, so a station or entrance says what it
  # is on the second line instead.
  attr :stop, :map, required: true
  attr :version_id, :any, required: true

  defp stop_link(assigns) do
    stop = assigns.stop

    assigns =
      assigns
      |> assign(:name, stop_display_name(stop))
      |> assign(:description, stop_description(stop))
      |> assign(:type_label, non_default_type_label(stop))

    ~H"""
    <.link
      navigate={~p"/gtfs/#{@version_id}/stops/#{@stop.stop_id}"}
      class="group flex min-h-11 flex-col justify-center after:absolute after:inset-0"
    >
      <span class="truncate font-[650] text-strong group-hover:underline" title={@name}>{@name}</span>
      <span
        :if={@description || @type_label}
        class="truncate text-[13px] font-normal text-muted"
      >
        <span :if={@type_label} class="lg:hidden">{@type_label}<span :if={@description}> · </span></span>{@description}
      </span>
    </.link>
    """
  end

  # Routes read as badges. A stop no trip serves says so, and a failed route
  # lookup says "Unavailable", so an empty cell is never mistaken for
  # "not served".
  attr :routes, :list, required: true
  attr :state, :atom, required: true

  defp stop_routes(%{state: :route_enrichment_unavailable} = assigns) do
    ~H"""
    <span class="text-muted">Unavailable</span>
    """
  end

  defp stop_routes(%{routes: []} = assigns) do
    ~H"""
    <span class="text-muted">Not served</span>
    """
  end

  defp stop_routes(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-1">
      <RouteIdentity.route_badge
        :for={route <- Enum.take(@routes, 5)}
        route={route}
        class="min-h-[26px] min-w-[30px] text-[13px]"
      />
      <span :if={length(@routes) > 5} class="text-[13px] text-muted">
        +{length(@routes) - 5} more
      </span>
    </div>
    """
  end

  # Wheelchair access, quiet where it is the common case and loud where it is
  # the exception: "Accessible" is plain green text, "Not recorded" is muted,
  # and only "Not accessible" gets a tinted badge. Every state carries an icon
  # and a word, so colour is never the only signal.
  attr :status, :atom, required: true, values: [:accessible, :not_accessible, :unknown]

  defp wheelchair_access(%{status: :accessible} = assigns) do
    ~H"""
    <span data-accessibility="accessible" class="inline-flex items-center gap-1.5 text-success-fg">
      <.icon name="hero-check-circle" class="size-4 shrink-0" /> Accessible
    </span>
    """
  end

  defp wheelchair_access(%{status: :not_accessible} = assigns) do
    ~H"""
    <span
      data-accessibility="not_accessible"
      class="inline-flex items-center gap-1.5 rounded-badge bg-error-bg px-2 py-0.5 font-[650] text-error-fg"
    >
      <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" /> Not accessible
    </span>
    """
  end

  defp wheelchair_access(%{status: :unknown} = assigns) do
    ~H"""
    <span data-accessibility="unknown" class="inline-flex items-center gap-1.5 text-muted">
      <.icon name="hero-minus-circle" class="size-4 shrink-0" /> Not recorded
    </span>
    """
  end

  defp load_route_options(%{assigns: %{route_options_state: :loaded}} = socket, _org, _version),
    do: socket

  defp load_route_options(socket, organization_id, gtfs_version_id) do
    case Gtfs.load_stop_route_options(organization_id, gtfs_version_id) do
      {:ok, routes} ->
        socket
        |> assign(:available_routes, routes)
        |> assign(:route_options_state, :loaded)

      {:error, :unavailable} ->
        socket
        |> assign(:available_routes, [])
        |> assign(:route_options_state, :unavailable)
    end
  end

  defp apply_catalog_result(
         {:ok,
          %{
            rows: stops,
            total_count: total_count,
            page: canonical_page,
            routes_by_stop: routes_by_stop
          }},
         socket,
         opts
       ) do
    stops_with_routes =
      Enum.map(stops, fn s ->
        Map.put(s, :routes, Map.get(routes_by_stop, s.stop_id, []))
      end)

    socket =
      socket
      |> assign(:page, canonical_page)
      |> assign(:total_count, total_count)
      |> assign(:stops_empty?, stops == [])
      |> assign(:stops_state, :ready)
      |> put_stops(stops_with_routes)

    maybe_patch_page(socket, canonical_page, opts)
  end

  defp apply_catalog_result(
         {:partial,
          %{
            rows: stops,
            total_count: total_count,
            page: canonical_page
          }, :route_enrichment_unavailable},
         socket,
         opts
       ) do
    stops_with_empty_routes =
      Enum.map(stops, fn s -> Map.put(s, :routes, []) end)

    socket =
      socket
      |> assign(:page, canonical_page)
      |> assign(:total_count, total_count)
      |> assign(:stops_empty?, stops == [])
      |> assign(:stops_state, :route_enrichment_unavailable)
      |> put_stops(stops_with_empty_routes)

    maybe_patch_page(socket, canonical_page, opts)
  end

  defp apply_catalog_result({:error, :unavailable}, socket, _opts) do
    {:noreply,
     socket
     |> assign(:stops_empty?, true)
     |> assign(:stops_state, :unavailable)
     |> put_stops([])}
  end

  # The table and the phone list render the same stops, and one stream cannot be
  # rendered into both: LiveView keys stream items by DOM id.
  defp put_stops(socket, stops) do
    socket
    |> stream(:stops, stops, reset: true)
    |> stream(:stops_mobile, stops, reset: true)
  end

  defp maybe_patch_page(socket, canonical_page, opts) do
    if canonical_page != Keyword.fetch!(opts, :page) do
      query_params = build_query_params(socket, canonical_page)

      canonical_patch_identity =
        {socket.assigns.current_gtfs_version.id, Keyword.replace!(opts, :page, canonical_page)}

      {:noreply,
       socket
       |> assign(:canonical_patch_identity, canonical_patch_identity)
       |> push_patch(
         to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops?#{query_params}"
       )}
    else
      {:noreply, socket}
    end
  end

  defp has_active_constraints?(assigns) do
    search_active = assigns.search != ""
    filter_active = not no_filter_active?(assigns)
    search_active or filter_active
  end

  defp no_filter_active?(assigns) do
    params = assigns.filter_form.params

    params["wheelchair_boarding"] in [nil, ""] and
      params["route_id"] in [nil, ""] and
      params["direction_id"] in [nil, ""]
  end

  # Nothing in the version and nothing searched: the next step is to import.
  defp first_use_empty?(assigns) do
    assigns.stops_state in [:ready, :route_enrichment_unavailable] and assigns.stops_empty? and
      not has_active_constraints?(assigns)
  end

  # Search or filters exclude every stop.
  defp constrained_empty?(assigns) do
    assigns.stops_state in [:ready, :route_enrichment_unavailable] and assigns.stops_empty? and
      has_active_constraints?(assigns)
  end

  defp results_visible?(assigns) do
    assigns.stops_state == :loading or
      (assigns.stops_state in [:ready, :route_enrichment_unavailable] and not assigns.stops_empty?)
  end

  defp only_search_active?(assigns) do
    assigns.search != "" and no_filter_active?(assigns)
  end

  # While route information is unavailable there is nothing to choose, so the
  # route select is off unless a route is already chosen: the person can still
  # clear it, and the form keeps submitting its value.
  defp route_filter_disabled?(assigns) do
    assigns.stops_state == :loading or
      ((assigns.stops_state == :route_enrichment_unavailable or
          assigns.route_options_state == :unavailable) and assigns.route_id in [nil, ""])
  end

  defp no_match_title(assigns) do
    if only_search_active?(assigns),
      do: "No stops match “#{assigns.search}”",
      else: "No stops match these filters"
  end

  defp no_match_hint(assigns) do
    if only_search_active?(assigns) do
      "Check the spelling, or clear the search to see every stop."
    else
      "Remove a filter above, or clear them all. Some stops have no route or wheelchair access recorded."
    end
  end

  # One entry per active constraint: the query param it dismisses, what kind of
  # constraint it is, and the value the person chose (not the raw param).
  defp active_filters(assigns) do
    params = assigns.filter_form.params

    [
      {"search", "Search", assigns.search != "", "“#{assigns.search}”"},
      {"route_id", "Route", Values.present?(params["route_id"]),
       route_label(assigns.available_routes, params["route_id"])},
      {"direction_id", "Direction", Values.present?(params["direction_id"]),
       direction_filter_label(params["direction_id"])},
      {"wheelchair_boarding", "Wheelchair access", Values.present?(params["wheelchair_boarding"]),
       access_filter_label(params["wheelchair_boarding"])}
    ]
    |> Enum.filter(fn {_key, _kind, active?, _value} -> active? end)
    |> Enum.map(fn {key, kind, _active?, value} -> %{key: key, kind: kind, value: value} end)
  end

  defp route_label(available_routes, route_id) do
    case Enum.find(available_routes, &(&1.route_id == route_id)) do
      %{route_short_name: short} when short not in [nil, ""] -> short
      _ -> route_id
    end
  end

  defp direction_filter_label("0"), do: Trip.direction_label(0)
  defp direction_filter_label("1"), do: Trip.direction_label(1)
  defp direction_filter_label(other), do: other

  defp access_filter_label("1"), do: "Accessible"
  defp access_filter_label("2"), do: "Not accessible"
  defp access_filter_label("0"), do: "Not recorded"
  defp access_filter_label(other), do: other

  # A blank name falls back to the ID, so a row always has something to open.
  defp stop_display_name(%{stop_name: name, stop_id: stop_id}) do
    case Values.presence(name) do
      nil -> stop_id
      name -> name
    end
  end

  defp stop_description(%{stop_desc: desc}), do: Values.presence(desc)

  # Most rows are plain stops, so only a station or entrance names its type
  # where the Type column is hidden.
  defp non_default_type_label(%{location_type: type}) when type in [0, nil], do: nil
  defp non_default_type_label(%{location_type: type}), do: Stop.location_type_label(type)

  # The phone list's second line: what tells one stop from another.
  defp stop_meta(stop) do
    ["ID #{stop.stop_id}", non_default_type_label(stop), stop_description(stop)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp build_query_params(socket, page) do
    %{}
    |> Values.put_present(
      "wheelchair_boarding",
      socket.assigns.filter_form.params["wheelchair_boarding"]
    )
    |> Values.put_present("route_id", socket.assigns.filter_form.params["route_id"])
    |> Values.put_present("direction_id", socket.assigns.filter_form.params["direction_id"])
    |> Values.put_present("search", socket.assigns.search)
    |> Values.put_present("sort_by", socket.assigns.sort_by)
    |> Values.put_present("sort_dir", socket.assigns.sort_dir)
    |> Map.put("page", page)
  end

  defp route_options(available_routes, selected_route_id) do
    options =
      Enum.map(available_routes, fn route ->
        display =
          if route.route_short_name do
            "#{route.route_short_name} (#{route.route_id})"
          else
            route.route_id
          end

        {display, route.route_id}
      end)

    if selected_route_id in [nil, ""] or
         Enum.any?(available_routes, &(&1.route_id == selected_route_id)) do
      options
    else
      [{selected_route_id, selected_route_id} | options]
    end
  end

  defp accessibility_status(%{wheelchair_boarding: 1}), do: :accessible
  defp accessibility_status(%{wheelchair_boarding: 2}), do: :not_accessible
  defp accessibility_status(_), do: :unknown

  # Drops nested values (`?page[a]=b`) and NUL bytes, which Postgres rejects, so
  # every remaining parameter is a plain string the parsers below can handle.
  defp valid_params(params) do
    Map.filter(params, fn {_key, value} ->
      is_binary(value) and not String.contains?(value, <<0>>)
    end)
  end

  defp parse_wheelchair(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int in 0..2 -> int
      _ -> nil
    end
  end

  defp parse_wheelchair(_), do: nil

  defp parse_direction(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int in 0..1 -> int
      _ -> nil
    end
  end

  defp parse_direction(_), do: nil

  defp parse_sort_dir("desc"), do: :desc
  defp parse_sort_dir(_), do: :asc

  defp maybe_put_sort(map, :stop_name, :asc), do: map

  defp maybe_put_sort(map, sort_by, sort_dir) do
    map
    |> Map.put("sort_by", sort_by)
    |> Map.put("sort_dir", sort_dir)
  end

  defp parse_column_atom(column)
       when column in ["stop_id", "stop_name", "location_type"] do
    String.to_existing_atom(column)
  end

  defp parse_column_atom(_), do: nil
end
