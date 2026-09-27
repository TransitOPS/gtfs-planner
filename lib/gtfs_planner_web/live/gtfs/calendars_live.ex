defmodule GtfsPlannerWeb.Gtfs.CalendarsLive do
  @moduledoc """
  Listing surface for the editable service calendars of one published version.

  The list is a read-only view over the scoped union read model: identities come
  from the weekly, exception and metadata tables through
  `Gtfs.load_calendar_catalog/3`, grouped trip usage and agency-local date
  summaries come from the same domain read, and the version-wide service gaps
  come from `Gtfs.load_calendar_feed_status/2`. Search, status and sort are URL
  state with allowlists, so reload and back navigation reproduce the list.

  States stay distinct: the first paint of a slow load renders the skeleton, a
  failed read renders the retry callout (never an empty list), an explicit refresh
  keeps the loaded rows while it reports progress, and only a successful read with
  no identities renders the first-use empty state. Calendar creation, the detail
  editor and the cross-calendar drawer belong to later steps, so this surface
  exposes no create, edit or date-change controls.

  Requires pathways_studio_editor, the same guard as the route and stop catalogs.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @status_options [
    {"All calendars", "all"},
    {"Active period", "active_period"},
    {"Active today", "active_today"},
    {"Ends within 14 days", "ends_soon"},
    {"Ended", "ended"},
    {"Not used by trips", "unused"}
  ]
  @status_keys Enum.map(@status_options, &elem(&1, 1))
  @sort_keys ~w(name period)
  @sort_dirs ~w(asc desc)
  @week_days [
    {"Mon", :monday},
    {"Tue", :tuesday},
    {"Wed", :wednesday},
    {"Thu", :thursday},
    {"Fri", :friday},
    {"Sat", :saturday},
    {"Sun", :sunday}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Calendars")
     |> assign(:status_options, @status_options)
     |> assign(:calendars_state, :loading)
     |> assign(:all_calendars, [])
     |> assign(:calendars, [])
     |> assign(:counts, %{calendars: 0, run_today: 0, ending_soon: 0})
     |> assign(:today, nil)
     |> assign(:gaps, [])
     |> assign(:calendars_empty?, false)
     |> assign(:filtered_empty?, false)
     |> assign(:constraints?, false)
     |> assign(:search, "")
     |> assign(:status, "all")
     |> assign(:sort_by, "name")
     |> assign(:sort_dir, "asc")
     |> assign_filter_form()
     |> stream_configure(:calendars, dom_id: &"calendar-#{URI.encode_www_form(&1.service_id)}")
     |> stream(:calendars, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:search, params["search"] || "")
      |> assign(:status, allowlisted(params["status"], @status_keys, "all"))
      |> assign(:sort_by, allowlisted(params["sort_by"], @sort_keys, "name"))
      |> assign(:sort_dir, allowlisted(params["sort_dir"], @sort_dirs, "asc"))
      |> assign_filter_form()

    if socket.assigns.calendars_state == :loading do
      send(self(), :load_calendars)
      {:noreply, socket}
    else
      {:noreply, load_calendars(socket)}
    end
  end

  @impl true
  def handle_info(:load_calendars, socket), do: {:noreply, load_calendars(socket)}

  @impl true
  def handle_event("filters", params, socket) do
    {:noreply, push_patch(socket, to: calendars_path(socket, to_query(socket, params)))}
  end

  @impl true
  def handle_event("sort", %{"key" => key}, socket) do
    sort_by = allowlisted(key, @sort_keys, "name")
    sort_dir = next_sort_dir(socket.assigns.sort_by, socket.assigns.sort_dir, sort_by)

    {:noreply,
     push_patch(socket, to: calendars_path(socket, to_query(socket, %{}, sort_by, sort_dir)))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: calendars_path(socket, %{}))}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    send(self(), :load_calendars)
    {:noreply, assign(socket, :calendars_state, :refreshing)}
  end

  @impl true
  def handle_event("retry", _params, socket) do
    send(self(), :load_calendars)
    {:noreply, assign(socket, :calendars_state, :loading)}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: calendars_path(socket, %{}, nil, nil, version_id))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: calendars_path(socket, %{}, nil, nil, version_id))}
    else
      {:noreply, socket}
    end
  end

  ## Data loading

  defp load_calendars(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    opts = [
      sort_by: String.to_existing_atom(socket.assigns.sort_by),
      sort_dir: String.to_existing_atom(socket.assigns.sort_dir)
    ]

    with {:ok, summaries} <- Gtfs.load_calendar_catalog(organization_id, version_id, opts),
         {:ok, feed_status} <- Gtfs.load_calendar_feed_status(organization_id, version_id) do
      socket
      |> assign(:all_calendars, summaries)
      |> assign(:today, feed_status.today)
      |> assign(:gaps, feed_status.gaps)
      |> assign(:calendars_state, :ready)
      |> assign_rows()
    else
      {:error, :unavailable} ->
        unavailable(socket)

      {:error, :not_found} ->
        socket
        |> assign(:calendars_state, :not_found)
        |> assign(:all_calendars, [])
        |> assign(:calendars, [])
        |> assign(:calendars_empty?, false)
        |> assign(:filtered_empty?, false)
        |> stream(:calendars, [], reset: true)
    end
  end

  # A failed read is never an empty list: the rows and their counts are dropped
  # and the retry callout takes their place.
  defp unavailable(socket) do
    socket
    |> assign(:calendars_state, :unavailable)
    |> assign(:all_calendars, [])
    |> assign(:calendars, [])
    |> assign(:calendars_empty?, false)
    |> assign(:filtered_empty?, false)
    |> assign(:today, nil)
    |> assign(:gaps, [])
    |> stream(:calendars, [], reset: true)
  end

  defp assign_rows(socket) do
    all = socket.assigns.all_calendars
    search = socket.assigns.search
    status = socket.assigns.status

    matches = Enum.filter(all, &(matches?(&1, search) and matches_status?(&1, status)))

    socket
    |> assign(:calendars, matches)
    |> assign(:counts, %{
      calendars: length(all),
      run_today: Enum.count(all, & &1.status.active_today?),
      ending_soon: Enum.count(all, & &1.status.ends_soon?)
    })
    |> assign(:calendars_empty?, all == [])
    |> assign(:filtered_empty?, matches == [])
    |> assign(:constraints?, search != "" or status != "all")
    |> stream(:calendars, matches,
      reset: true,
      dom_id: &"calendar-#{URI.encode_www_form(&1.service_id)}"
    )
  end

  defp matches?(_summary, ""), do: true

  defp matches?(summary, search) do
    term = String.downcase(search)

    String.contains?(String.downcase(summary.name || summary.service_id), term) or
      String.contains?(String.downcase(summary.service_id), term)
  end

  defp matches_status?(_summary, "all"), do: true
  defp matches_status?(summary, "active_period"), do: summary.status.active_period?
  defp matches_status?(summary, "active_today"), do: summary.status.active_today?
  defp matches_status?(summary, "ends_soon"), do: summary.status.ends_soon?
  defp matches_status?(summary, "ended"), do: summary.status.ended?
  defp matches_status?(summary, "unused"), do: not summary.status.used_by_trips?

  ## URL state

  defp assign_filter_form(socket) do
    assign(
      socket,
      :filter_form,
      to_form(%{"search" => socket.assigns.search, "status" => socket.assigns.status})
    )
  end

  defp to_query(socket, params, sort_by \\ nil, sort_dir \\ nil) do
    %{}
    |> put_param("search", params["search"] || socket.assigns.search, "")
    |> put_param("status", params["status"] || socket.assigns.status, "all")
    |> put_param("sort_by", sort_by || socket.assigns.sort_by, "name")
    |> put_param("sort_dir", sort_dir || socket.assigns.sort_dir, "asc")
  end

  defp calendars_path(socket, query, _sort_by \\ nil, _sort_dir \\ nil, version_id \\ nil) do
    version_id = version_id || socket.assigns.current_gtfs_version.id

    case URI.encode_query(query) do
      "" -> "/gtfs/#{version_id}/calendars"
      encoded -> "/gtfs/#{version_id}/calendars?#{encoded}"
    end
  end

  defp put_param(query, _key, nil, _default), do: query
  defp put_param(query, _key, value, value), do: query
  defp put_param(query, key, value, _default), do: Map.put(query, key, value)

  defp next_sort_dir(current_key, current_dir, key) do
    case {current_key, current_dir, key} do
      {key, "asc", key} -> "desc"
      {_other, _dir, _key} -> "asc"
    end
  end

  defp allowlisted(value, allowed, default) do
    if value in allowed, do: value, else: default
  end

  ## Presentation helpers

  defp column_sort_state(sort_by, sort_dir, column) do
    if column == sort_by, do: sort_dir, else: "none"
  end

  defp regular_days(%{calendar: nil}), do: "Specific dates"

  defp regular_days(%{calendar: calendar}) do
    days = for {label, field} <- @week_days, Map.fetch!(calendar, field) == 1, do: label

    case days do
      ["Mon", "Tue", "Wed", "Thu", "Fri"] -> "Mon–Fri"
      ["Sat", "Sun"] -> "Sat–Sun"
      ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] -> "Every day"
      [] -> "No weekly days"
      other -> Enum.join(other, ", ")
    end
  end

  defp service_dates(%{first_active_date: nil}), do: "No service dates"
  defp service_dates(%{first_active_date: date, last_active_date: date}), do: format_date(date)

  defp service_dates(%{first_active_date: first, last_active_date: last}) do
    "#{format_date(first)} – #{format_date(last)}"
  end

  defp format_date(date), do: Calendar.strftime(date, "%b %-d, %Y")

  defp badge(%{status: %{ended?: true}}), do: {:draft, "Ended"}

  defp badge(%{status: %{ends_soon?: true, days_remaining: 0}}), do: {:warning, "Ends today"}

  defp badge(%{status: %{ends_soon?: true, days_remaining: days}}),
    do: {:warning, "Ends in #{days} days"}

  defp badge(%{status: %{no_service?: true}}), do: {:warning, "No service"}

  defp badge(%{status: %{used_by_trips?: false}}), do: {:draft, "Not used by trips"}
  defp badge(%{status: %{active_today?: true}}), do: {:active, "Runs today"}
  defp badge(_summary), do: {:draft, "Scheduled"}

  defp gap_label(%{first_date: date, last_date: date}), do: format_date(date)

  defp gap_label(%{first_date: first, last_date: last}),
    do: "#{format_date(first)} – #{format_date(last)}"

  defp result_count(%{constraints?: true} = assigns) do
    "#{length(assigns.calendars)} of #{assigns.counts.calendars} calendars"
  end

  defp result_count(assigns), do: "#{assigns.counts.calendars} calendars"

  ## Render

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
        Calendars
        <:subtitle>Set the days your trips run, including holidays and breaks.</:subtitle>
      </.header>

      <div
        :if={@calendars_state == :loading}
        id="calendars-loading"
        class="mt-6 bg-base-100 border border-base-300 rounded-box p-4"
        aria-busy="true"
      >
        <.skeleton rows={4} label="Loading calendars…" />
      </div>

      <div :if={@calendars_state == :unavailable} id="calendars-unavailable" class="mt-6" role="alert">
        <.callout kind="error" title="Calendars couldn’t be loaded">
          Try again to see calendars for this service version.
          <.button
            id="calendars-retry"
            phx-click="retry"
            variant="secondary"
            size="sm"
            class="mt-2"
          >
            Retry
          </.button>
        </.callout>
      </div>

      <div :if={@calendars_state == :not_found} id="calendars-version-unavailable" class="mt-6">
        <.callout kind="info" title="Calendars aren’t available for this service version">
          Open a published version you can edit to review its calendars.
        </.callout>
      </div>

      <div :if={@calendars_state in [:ready, :refreshing]} class="mt-6 space-y-4">
        <p
          :if={@calendars_state == :refreshing}
          id="calendars-refreshing"
          role="status"
          class="text-sm text-base-content/70"
        >
          Refreshing calendars. The last loaded list stays visible.
        </p>

        <div :if={@calendars_state == :ready and not @calendars_empty?}>
          <div class="flex flex-wrap items-center gap-x-6 gap-y-2">
            <.count_strip
              id="calendar-counts"
              items={[
                %{key: "calendars", label: "calendars", count: @counts.calendars, tone: :neutral},
                %{key: "run-today", label: "run today", count: @counts.run_today, tone: :success},
                %{
                  key: "ending-soon",
                  label: "ending soon",
                  count: @counts.ending_soon,
                  tone: :warning
                }
              ]}
            />
            <span :if={@today} id="calendars-today" class="text-sm text-base-content/70">
              Today · {format_date(@today)}
            </span>
          </div>

          <div
            :if={@gaps != []}
            id="calendars-feed-gap"
            class="mt-4"
          >
            <.callout kind="warning" title={"No service on any calendar: #{gap_label(hd(@gaps))}"}>
              This may be intentional. If trips should run, add service for that date.
              <span :if={length(@gaps) > 1} class="block mt-1 text-sm">
                {length(@gaps)} service gaps exist between the first and last active dates.
              </span>
            </.callout>
          </div>
        </div>

        <.form
          :if={not @calendars_empty?}
          for={@filter_form}
          id="calendar-filter-form"
          phx-change="filters"
          class="bg-base-100 border border-base-300 rounded-box p-4 flex flex-wrap gap-4 items-end"
        >
          <div class="flex-1 min-w-[240px]">
            <.input
              id="calendar-search"
              field={@filter_form[:search]}
              type="search"
              label="Find a calendar"
              placeholder="Search by name or service ID"
              phx-debounce="300"
            />
          </div>
          <div class="flex-1 min-w-[200px]">
            <.input
              id="calendar-status"
              field={@filter_form[:status]}
              type="select"
              label="Show calendars"
              options={@status_options}
            />
          </div>
          <div class="flex items-center gap-3">
            <.button id="calendar-refresh" phx-click="refresh" variant="secondary" size="sm">
              Refresh
            </.button>
            <span
              id="result-count"
              role="status"
              aria-live="polite"
              class="text-sm text-base-content/70"
            >
              {result_count(assigns)}
            </span>
          </div>
        </.form>

        <div
          :if={@calendars_empty? and @calendars_state == :ready}
          id="calendars-first-use-empty"
        >
          <.empty_state title="No calendars yet">
            Calendars say which days trips run. Start with a regular schedule, such as weekdays, or
            choose specific dates.
          </.empty_state>
        </div>

        <div
          :if={@filtered_empty? and not @calendars_empty? and @calendars_state == :ready}
          id="calendars-filtered-empty"
        >
          <.empty_state title="No calendars match these filters">
            Try another name or show all calendars.
            <:action>
              <.button
                id="calendars-clear-filters"
                phx-click="clear_filters"
                variant="secondary"
                size="sm"
              >
                Clear filters
              </.button>
            </:action>
          </.empty_state>
        </div>

        <div
          :if={@calendars != []}
          id="calendars-results"
          class="bg-base-100 border border-base-300 rounded-box"
        >
          <.table id="calendars-list" rows={@streams.calendars} responsive="stack">
            <:col
              :let={{_id, summary}}
              label="Calendar"
              sort_key="name"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, "name")}
            >
              <.link
                navigate={detail_path(assigns, summary)}
                class="link link-primary font-semibold"
              >
                {summary.name || "Untitled calendar"}
              </.link>
              <div class="text-sm text-base-content/70">
                <code class="font-mono">{summary.service_id}</code>
              </div>
            </:col>
            <:col :let={{_id, summary}} label="Regular days">
              {regular_days(summary)}
            </:col>
            <:col
              :let={{_id, summary}}
              label="Service dates"
              sort_key="period"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, "period")}
            >
              {service_dates(summary)}
            </:col>
            <:col :let={{_id, summary}} label="Trips" align="right">
              <span class="tabular-nums">{summary.trip_count}</span>
            </:col>
            <:col :let={{_id, summary}} label="Status">
              <% {tone, word} = badge(summary) %>
              <.status_badge status={tone} label={word} />
            </:col>
          </.table>
        </div>

        <p :if={not @calendars_empty?} class="text-sm text-base-content/70">
          A calendar can be shared by several routes. Changes affect every trip that uses it.
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp detail_path(assigns, summary) do
    "/gtfs/#{assigns.current_gtfs_version.id}/calendars/show?service_id=" <>
      URI.encode_www_form(summary.service_id)
  end
end
