defmodule GtfsPlannerWeb.Gtfs.PathwayEvolutionsLive do
  @moduledoc """
  LiveView for a station's scheduled pathway closures.

  This page replaces the Evolutions placeholder. It mounts through the ordinary
  `:gtfs_routes` session and the `:require_gtfs_access` guard, so a member
  without the editor role never reaches it, and it reuses the station
  sub-navigation with `active_tab: :evolutions` — the fifth tab and its stable
  `#station-tab-evolutions` id are unchanged, only the destination behind them
  is real.

  Everything on the page is a read of saved domain state. The list is built from
  `Gtfs.station_closures/3`, whose `:not_found` refusal covers an unknown,
  foreign, non-station or unpublished target: those never reach a render, so no
  row, count or label can leak from another organization, version or stop. The
  native calendar options come from `Gtfs.closure_calendars/2` in the same
  scope; that read cannot refuse once `station_closures/3` has succeeded, because
  both validate the same scope, so its result is matched rather than defaulted to
  an empty list that would claim the version has no calendars.

  Row identity is the closure UUID, and each row's exact `pathway_id` and
  `service_id` travel in text and data attributes, so a natural ID containing a
  slash, percent sign, space or other punctuation round-trips through a link
  without conflation. `?pathway=` filters the visible, clearable search to one
  exact pathway of this station; `?closure=` selects one closure of this station
  by UUID. A value outside the scope is ignored rather than resolved, so a
  foreign closure id exposes nothing. `?closure` is applied after `?pathway` and
  clears the filter, because a selected row has to be visible to be selected.

  The page writes nothing. Saving, deleting and access analysis are later steps;
  until then the inspector is absent, and every control here either filters the
  list or announces what it did in the polite `#evolutions-status` region.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.PathwayEvolutionsComponents

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Evolutions")
     |> assign(:station, nil)
     |> assign(:stop_id, nil)
     |> assign(:station_data, nil)
     |> assign(:calendars, [])
     |> assign(:search, "")
     |> assign(:selected_closure_id, nil)
     |> assign(:selected_pathway_id, nil)
     |> assign(:status_message, nil)
     |> assign(:blocked, nil)
     |> assign(:first_use?, false)
     |> assign(:filtered_empty?, false)
     |> assign(:closure_count, pluralize_closures(0))
     |> assign(:match_count, 0)
     |> assign(:pathway_groups, [])
     |> assign(:closure_counts, %{})
     |> stream_configure(:closures, dom_id: &"closure-#{&1.id}")
     |> stream(:closures, [])}
  end

  @impl true
  def handle_params(%{"stop_id" => stop_id} = params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.station_closures(organization_id, gtfs_version_id, stop_id) do
      {:error, :not_found} ->
        # A foreign, absent, unpublished or non-station target is not an
        # Evolutions station, and a non-station stop is never one. The flash
        # states why; no closure, pathway or calendar name is read for it.
        {:noreply,
         socket
         |> put_flash(:error, "Station not found")
         |> push_navigate(to: ~p"/gtfs/#{gtfs_version_id}/stops")}

      {:ok, station_data} ->
        {:ok, calendars} = Gtfs.closure_calendars(organization_id, gtfs_version_id)

        socket =
          socket
          |> assign(
            station: station_data.station,
            stop_id: stop_id,
            station_data: station_data,
            calendars: calendars
          )
          |> apply_deep_links(params)

        {:noreply, render_closures(socket)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"search" => search}, socket) when is_binary(search) do
    # The entered value is kept whether or not it matches anything: a filtered
    # empty state offers "Clear search", and a retained value is what makes the
    # filtered-empty state different from the first-use empty state.
    {:noreply,
     socket
     |> assign(:search, search)
     |> assign(:selected_pathway_id, nil)
     |> render_closures()}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search, "")
     |> assign(:selected_pathway_id, nil)
     |> assign(:status_message, "Search cleared. Showing every closure at this station.")
     |> render_closures()}
  end

  def handle_event("select_closure", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.station_data.closures, &(to_string(&1.evolution.id) == id)) do
      nil ->
        {:noreply, socket}

      %{evolution: evolution, pathway: pathway} ->
        {:noreply,
         socket
         |> assign(:selected_closure_id, evolution.id)
         |> assign(:status_message, "Selected closure on #{pathway_label(pathway)}.")
         |> refresh_rows()}
    end
  end

  def handle_event("select_pathway", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.station_data.pathways, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      pathway ->
        # The locator is also a filter: choosing a pathway fills the visible
        # search with its exact ID, so the table shows that pathway's closures
        # and the filter can be cleared without leaving the page.
        {:noreply,
         socket
         |> assign(:selected_pathway_id, pathway.id)
         |> assign(:search, pathway.pathway_id)
         |> assign(:selected_closure_id, nil)
         |> assign(:status_message, "Filtered to #{pathway_label(pathway)}.")
         |> render_closures()}
    end
  end

  def handle_event("start_closure", _params, socket) do
    {:noreply,
     socket
     |> assign(:search, "")
     |> assign(:selected_pathway_id, nil)
     |> assign(:selected_closure_id, nil)
     |> assign(:status_message, "Choose a pathway below to schedule a closure.")
     |> render_closures()}
  end

  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: version_target(socket, version_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply, push_navigate(socket, to: version_target(socket, version_id))}
    else
      {:noreply, socket}
    end
  end

  # The station is kept across a version change only because the mount resolves
  # it again in the new scope. A version that does not hold the station reaches
  # the missing-station response, which flashes and returns to that version's
  # stops list rather than rendering an empty station under its name.
  defp version_target(socket, version_id) do
    case socket.assigns.stop_id do
      stop_id when is_binary(stop_id) ->
        ~p"/gtfs/#{version_id}/stops/#{stop_id}/evolutions"

      _absent ->
        ~p"/gtfs/#{version_id}/stops"
    end
  end

  # -- deep links -------------------------------------------------------------

  # `?pathway` first, then `?closure`: a selected closure has to be visible, so
  # selecting one clears the pathway filter. A value outside this station's
  # scope is ignored, so a foreign closure UUID or another station's pathway
  # exposes nothing and does not silently filter the list to nothing.
  defp apply_deep_links(socket, params) do
    socket
    |> maybe_select_pathway(params["pathway"])
    |> maybe_select_closure(params["closure"])
  end

  defp maybe_select_pathway(socket, pathway_id) when is_binary(pathway_id) do
    case Enum.find(socket.assigns.station_data.pathways, &(&1.pathway_id == pathway_id)) do
      nil ->
        socket

      pathway ->
        socket
        |> assign(:search, pathway.pathway_id)
        |> assign(:selected_pathway_id, pathway.id)
    end
  end

  defp maybe_select_pathway(socket, _other), do: socket

  defp maybe_select_closure(socket, closure_id) when is_binary(closure_id) do
    case Enum.find(
           socket.assigns.station_data.closures,
           &(to_string(&1.evolution.id) == closure_id)
         ) do
      nil ->
        socket

      %{evolution: evolution, pathway: pathway} ->
        socket
        |> assign(:selected_closure_id, evolution.id)
        |> assign(:search, "")
        |> assign(:status_message, "Selected closure on #{pathway_label(pathway)}.")
    end
  end

  defp maybe_select_closure(socket, _other), do: socket

  # -- list -------------------------------------------------------------------

  # One place rebuilds the visible rows, so the count, the states and the
  # streamed rows can never disagree about what the search matched.
  defp render_closures(socket) do
    data = socket.assigns.station_data
    rows = closure_rows(data.closures)
    matches = filter_rows(rows, socket.assigns.search, data.pathways)

    blocked =
      cond do
        data.pathways == [] -> :no_pathways
        socket.assigns.calendars == [] -> :no_calendars
        true -> nil
      end

    first_use? = is_nil(blocked) and rows == []
    filtered_empty? = is_nil(blocked) and rows != [] and matches == []

    socket
    |> assign(:blocked, blocked)
    |> assign(:first_use?, first_use?)
    |> assign(:filtered_empty?, filtered_empty?)
    |> assign(:closure_count, pluralize_closures(length(rows)))
    |> assign(:match_count, length(matches))
    |> assign(:pathway_groups, mode_groups(data.pathways))
    |> assign(:closure_counts, closure_counts(rows))
    |> assign(:rows, rows)
    |> stream(:closures, matches, reset: true)
  end

  # A selection changes the styling of at most two rows and never the visible
  # set, so the rows are re-inserted in place rather than through a stream
  # reset: the row a keyboard user activated keeps its DOM node, and therefore
  # its focus, while `aria-current` and the selection styling still update.
  # `update_only: true` skips every row the current filter has not rendered.
  defp refresh_rows(socket) do
    Enum.reduce(socket.assigns.rows, socket, &stream_insert(&2, :closures, &1, update_only: true))
  end

  defp closure_rows(closures) do
    closures
    # Mode order first, then the exact natural ID, then the service-day start:
    # the table reads in the same order as the pathway list below it, and two
    # closures on one pathway stay in time order.
    |> Enum.sort_by(fn %{evolution: evolution, pathway: pathway} ->
      {pathway_rank(pathway.pathway_mode), pathway.pathway_id, evolution.start_time}
    end)
    |> Enum.map(fn %{evolution: evolution, pathway: pathway, calendar: calendar} ->
      {calendar_label, calendar_detail} = calendar_lines(calendar, evolution.service_id)

      %{
        id: evolution.id,
        pathway_id: evolution.pathway_id,
        pathway_label: pathway_label(pathway),
        service_id: evolution.service_id,
        calendar_label: calendar_label,
        calendar_detail: calendar_detail,
        window: window_label(evolution),
        window_note: window_note(evolution)
      }
    end)
  end

  # A term that is exactly one of this station's pathway IDs selects that
  # pathway and nothing else, so `?pathway=PW-A` can never be widened into
  # `PW-AB`. Any other term is a free-text search across the pathway and
  # calendar labels and both exact natural IDs, which is what the visible
  # "Find pathway or calendar" control promises.
  defp filter_rows(rows, search, pathways) do
    case exact_pathway_id(search, pathways) do
      nil ->
        case normalize(search) do
          "" -> rows
          term -> Enum.filter(rows, &matches?(row_term_strings(&1), term))
        end

      pathway_id ->
        Enum.filter(rows, &(&1.pathway_id == pathway_id))
    end
  end

  defp exact_pathway_id(search, pathways) do
    term = normalize(search)

    if term == "" do
      nil
    else
      Enum.find_value(pathways, fn pathway ->
        if normalize(pathway.pathway_id) == term, do: pathway.pathway_id
      end)
    end
  end

  defp matches?([pathway_label, pathway_id, calendar_label, calendar_detail, service_id], term) do
    Enum.any?(
      [pathway_label, pathway_id, calendar_label, calendar_detail, service_id],
      &String.contains?(normalize(&1 || ""), term)
    )
  end

  defp row_term_strings(row) do
    [
      row.pathway_label,
      row.pathway_id,
      row.calendar_label,
      row.calendar_detail,
      row.service_id
    ]
  end

  defp closure_counts(rows) do
    Enum.reduce(rows, %{}, fn row, counts ->
      Map.update(counts, row.pathway_id, 1, &(&1 + 1))
    end)
  end

  defp normalize(value), do: value |> String.trim() |> String.downcase()

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
        <.station_sub_nav
          station={@station}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:evolutions}
        />
      </:sub_header>

      <div id="evolutions" class="mt-5">
        <p
          id="evolutions-status"
          role="status"
          aria-live="polite"
          class={[
            "mb-4 rounded-control border border-subtle bg-canvas px-4 py-2.5 text-sm",
            @status_message && "text-strong",
            !@status_message && "hidden"
          ]}
        >
          {@status_message}
        </p>

        <section
          id="closures-card"
          aria-labelledby="closures-title"
          class="min-w-0 rounded-card border border-subtle bg-white"
        >
          <div class="flex flex-wrap items-end justify-between gap-x-4 gap-y-3 border-b border-subtle px-4 py-4 md:px-5">
            <div class="min-w-0 self-center">
              <h2
                id="closures-title"
                class="font-sans text-[18px] font-[650] leading-snug tracking-normal"
              >
                Closures at this station
              </h2>
              <p
                :if={list_visible?(@blocked, @first_use?)}
                id="closures-count"
                class="text-[13px] tabular-nums text-muted"
              >
                {count_text(@match_count, @closure_count, @search)}
              </p>
            </div>

            <div
              :if={list_visible?(@blocked, @first_use?)}
              id="closures-tools"
              class="flex w-full flex-wrap items-end gap-3 sm:w-auto"
            >
              <div class="grid min-w-0 flex-1 gap-1.5 sm:w-60 sm:flex-none">
                <label for="closures-search" class="text-[13px] font-[650] text-base-content">
                  Find pathway or calendar
                </label>
                <form
                  id="closures-search-form"
                  phx-change="search"
                  phx-debounce="200"
                  class="contents"
                >
                  <div class="relative">
                    <.icon
                      name="hero-magnifying-glass"
                      class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted"
                    />
                    <input
                      id="closures-search"
                      type="search"
                      name="search"
                      value={@search}
                      autocomplete="off"
                      aria-label="Find pathway or calendar"
                      class="h-11 w-full rounded-control border border-control bg-white pr-3 pl-9 text-sm text-strong"
                    />
                  </div>
                </form>
              </div>
              <.button
                id="new-closure"
                type="button"
                phx-click="start_closure"
                variant="secondary"
                class="h-11 min-h-11 gap-2 rounded-control border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas"
              >
                <.icon name="hero-plus" class="size-4" /> Create closure
              </.button>
            </div>
          </div>

          <table
            :if={is_nil(@blocked) and @match_count > 0}
            id="closures-table"
            class="w-full border-collapse text-left text-sm"
          >
            <thead>
              <tr>
                <th
                  scope="col"
                  class="w-[46%] border-b border-subtle bg-canvas py-2.5 pr-3 pl-5 text-[13px] font-[650] text-base-content"
                >
                  Pathway
                </th>
                <th
                  scope="col"
                  class="border-b border-subtle bg-canvas px-3 py-2.5 text-[13px] font-[650] text-base-content"
                >
                  Calendar
                </th>
                <th
                  scope="col"
                  class="w-[152px] border-b border-subtle bg-canvas py-2.5 pr-5 pl-3 text-[13px] font-[650] text-base-content"
                >
                  Window
                </th>
              </tr>
            </thead>
            <tbody
              id="closures-list"
              phx-update="stream"
              tabindex="-1"
              class="focus-visible:outline-offset-[-2px]"
            >
              <tr
                :for={{dom_id, row} <- @streams.closures}
                id={dom_id}
                data-closure-id={row.id}
                class={closure_row_class(row, @selected_closure_id)}
              >
                <.closure_cells row={row} selected={to_string(row.id) == @selected_closure_id} />
              </tr>
            </tbody>
          </table>

          <.closures_state
            :if={@first_use?}
            id="closures-empty"
            title={"No closures scheduled at " <> station_name(@station)}
            message="A closure takes a pathway out of service during a daily window on a calendar’s service days, for example elevator maintenance."
          >
            <:action>
              <.button
                id="new-closure"
                type="button"
                phx-click="start_closure"
                class="h-11 min-h-11 gap-2 rounded-control bg-action px-4 text-sm font-[650] text-white hover:bg-evo-action-hover"
              >
                <.icon name="hero-plus" class="size-4" /> Create closure
              </.button>
            </:action>
          </.closures_state>

          <.closures_state
            :if={@filtered_empty?}
            id="closures-filtered-empty"
            title={"No closures match “" <> String.trim(@search) <> "”"}
            message={"Check the spelling, or clear the search to see all " <> @closure_count <> "."}
          >
            <:action>
              <.button
                id="closures-clear-search"
                type="button"
                phx-click={JS.push("clear_search") |> JS.focus(to: "#closures-search")}
                variant="secondary"
                class="h-11 min-h-11 rounded-control border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas"
              >
                Clear search
              </.button>
            </:action>
          </.closures_state>

          <.closures_state
            :if={@blocked == :no_pathways}
            id="closures-no-pathways"
            title={station_name(@station) <> " has no pathways yet"}
            message="A closure takes a pathway out of service. Add pathways between the station’s stops on its floorplan, then schedule closures here."
          >
            <:action>
              <.button
                id="closures-open-floorplans"
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/stops/#{@stop_id}/diagram"}
                class="h-11 min-h-11 rounded-control bg-action px-4 text-sm font-[650] text-white hover:bg-evo-action-hover"
              >
                Open floorplans
              </.button>
            </:action>
          </.closures_state>

          <.closures_state
            :if={@blocked == :no_calendars}
            id="closures-no-calendars"
            title={"No calendars in " <> @current_gtfs_version.name}
            message="A closure applies on a calendar’s service days. Create a calendar with the dates of the work, then schedule the closure here."
          >
            <:action>
              <.button
                id="closures-open-calendars"
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/calendars"}
                class="h-11 min-h-11 rounded-control bg-action px-4 text-sm font-[650] text-white hover:bg-evo-action-hover"
              >
                Open calendars
              </.button>
            </:action>
          </.closures_state>
        </section>

        <section
          :if={is_nil(@blocked)}
          id="closure-locator"
          aria-labelledby="closure-locator-title"
          class="mt-6 min-w-0 rounded-card border border-subtle bg-white"
        >
          <div class="border-b border-subtle px-4 py-4 md:px-5">
            <h2
              id="closure-locator-title"
              class="font-sans text-[18px] font-[650] leading-snug tracking-normal"
            >
              Choose a pathway
            </h2>
            <p class="text-[13px] text-muted">Any pathway type can close.</p>
          </div>

          <.pathway_list
            groups={@pathway_groups}
            closure_counts={@closure_counts}
            selected_id={@selected_pathway_id}
          />
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp station_name(%{stop_name: name}) when is_binary(name) and name != "", do: name
  defp station_name(%{stop_id: stop_id}), do: stop_id
  defp station_name(_station), do: "This station"

  # The count, the search and the header's Create closure action belong to a
  # list that exists. A blocked station and a station with nothing scheduled yet
  # both say so with their own state instead, and both carry an action inside
  # that state.
  defp list_visible?(blocked, first_use?), do: is_nil(blocked) and not first_use?

  defp count_text(_match_count, closure_count, search) when search == "", do: closure_count

  defp count_text(match_count, closure_count, _search),
    do: "#{match_count} of #{closure_count} match"
end
