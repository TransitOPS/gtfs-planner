defmodule GtfsPlannerWeb.Gtfs.TimetablePasteLive do
  @moduledoc """
  Paste timetable page shell: the header, the schedule line and the setup
  empty states, plus the Change schedule drawer.

  Step 21 owns the shell: `handle_params` resolves the paste scope through
  `Gtfs.prepare_timetable_paste/5` with the LiveView's input (blank, so
  `review: nil`) and canonicalizes the `service_id`/`direction`/`pattern`
  URL parameters with a replace patch, like `RouteSchedulesLive`
  canonicalizes its filters. A foreign scope navigates back to Routes with
  a not-found flash, also like `RouteSchedulesLive`.

  Step 22 owns the scope drawer: `open_scope_drawer` drafts the current
  scope (every calendar from `Gtfs.list_calendars/3`, the draft direction's
  patterns with trip counts), `scope_draft_change` refilters the draft
  patterns when the calendar or direction changes, and `change_schedule`
  `push_patch`es the new params while the LiveView keeps `input.text`,
  clears the overrides/confirmations/decisions and re-reviews with the new
  scope on the patch. The timetable step (step 23) and the review UI
  (steps 25-28) build on the `input`/`review` assigns kept here. The
  version-switch events mirror `RouteSchedulesLive`; the unsaved-work
  confirmation arrives in step 30.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.RouteWorkspace, only: [route_header: 1, route_label: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.TimetablePasteComponents

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @scope_keys ~w(service_id direction pattern)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Paste timetable")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:route_id, nil)
     |> assign(:route, nil)
     |> assign(:scope, nil)
     |> assign(:requested, %{})
     |> assign(:input, fresh_paste_input())
     |> assign(:review, nil)
     |> assign(:scope_draft, nil)
     |> assign(:scope_form, to_form(%{}, as: :scope))
     |> assign(:scope_calendars, [])
     |> assign(:draft_scope, nil)
     |> assign(:load_state, :loading)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:route_id, params["route_id"])
      |> assign(:requested, params)

    if connected?(socket) do
      {:noreply, load_scope(socket, params)}
    else
      {:noreply, assign(socket, :load_state, :loading)}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    switch_version(socket, version_id)
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    switch_version(socket, version_id)
  end

  # Step 22 owns the Change schedule drawer. Opening drafts the current
  # scope; the draft calendar/direction reload the draft scope for the
  # pattern options; submitting patches the URL and keeps the paste.
  @impl true
  def handle_event("open_scope_drawer", _params, socket) do
    case socket.assigns.scope do
      nil ->
        {:noreply, socket}

      scope ->
        calendars = load_scope_calendars(socket)
        draft = draft_params(scope)

        {:noreply,
         socket
         |> assign(:scope_calendars, calendars)
         |> assign(:scope_draft, draft)
         |> assign(:draft_scope, scope)
         |> assign(:scope_form, to_form(draft, as: :scope))}
    end
  end

  @impl true
  def handle_event("close_scope_drawer", _params, socket) do
    {:noreply, close_scope_drawer(socket)}
  end

  @impl true
  def handle_event("scope_draft_change", %{"scope" => params}, socket)
      when is_map(params) do
    case socket.assigns.scope_draft do
      nil ->
        {:noreply, socket}

      current ->
        draft = Map.merge(current, string_params(params))
        {draft, draft_scope} = refresh_draft_scope(socket, current, draft)

        {:noreply,
         socket
         |> assign(:scope_draft, draft)
         |> assign(:draft_scope, draft_scope)
         |> assign(:scope_form, to_form(draft, as: :scope))}
    end
  end

  @impl true
  def handle_event("scope_draft_change", _params, socket), do: {:noreply, socket}

  # Using the schedule patches the URL with the draft params. The LiveView
  # keeps `input.text`, clears the overrides/confirmations/decisions and
  # re-reviews with the new scope when the patch lands in `handle_params`.
  @impl true
  def handle_event("change_schedule", %{"scope" => params}, socket)
      when is_map(params) do
    case socket.assigns.scope_draft do
      nil ->
        {:noreply, socket}

      _draft ->
        query = schedule_query(params)

        {:noreply,
         socket
         |> close_scope_drawer()
         |> assign(:input, %{fresh_paste_input() | text: input_text(socket)})
         |> push_patch(to: paste_path(socket, query))}
    end
  end

  @impl true
  def handle_event("change_schedule", _params, socket), do: {:noreply, socket}

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
      <div id="timetable-paste" class="ds-page">
        <.route_header
          route={@route}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:schedules}
          loading={@load_state == :loading}
        />

        <TimetablePasteComponents.loading_skeleton :if={@load_state == :loading and is_nil(@scope)} />

        <div :if={@scope}>
          <div class="flex flex-wrap items-end justify-between gap-x-6 gap-y-3 pb-5 pt-7">
            <div class="min-w-0">
              <h1
                id="paste-title"
                tabindex="-1"
                class="font-display text-[28px] font-semibold leading-tight tracking-[-0.025em] text-strong outline-none"
              >
                Paste timetable
              </h1>
              <p class="mt-1.5 text-sm text-muted">
                Add trips from a spreadsheet, or replace a schedule with it. Nothing changes until
                you apply.
              </p>
            </div>
          </div>

          <TimetablePasteComponents.scope_line
            calendar={@scope.calendar}
            direction_name={direction_name(@scope.direction_id)}
            pattern={chosen_pattern(@scope)}
          />

          <TimetablePasteComponents.setup_empty
            :if={setup_reason(@scope)}
            reason={setup_reason(@scope)}
            route_label={route_label(@scope.route)}
            direction_adjective={direction_adjective(@scope.direction_id)}
            calendars_path={"/gtfs/#{@current_gtfs_version.id}/calendars/new"}
            patterns_path={~p"/gtfs/#{@current_gtfs_version.id}/routes/#{@route_id}/patterns/new"}
          />

          <TimetablePasteComponents.scope_drawer
            open={@scope_draft != nil}
            form={@scope_form}
            calendars={@scope_calendars}
            draft_scope={@draft_scope}
            review={@review}
            route_label={route_label(@scope.route)}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_scope(socket, params) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id
    input = socket.assigns[:input] || %{}

    case Gtfs.prepare_timetable_paste(
           organization_id,
           version_id,
           route_id,
           scope_params(params),
           input
         ) do
      {:ok, %{scope: scope, review: review}} -> apply_scope(socket, scope, review, params)
      {:error, :not_found} -> route_not_found(socket)
    end
  end

  defp scope_params(params) do
    %{
      service_id: params["service_id"],
      direction: params["direction"],
      pattern: params["pattern"]
    }
  end

  defp apply_scope(socket, scope, review, params) do
    socket
    |> assign(:route, scope.route)
    |> assign(:scope, scope)
    |> assign(:review, review)
    |> assign(:load_state, :ready)
    |> push_canonical(scope, params)
  end

  defp push_canonical(socket, scope, params) do
    canonical = canonical_scope_params(scope)

    if Map.take(params, @scope_keys) == canonical do
      socket
    else
      push_patch(socket, to: paste_path(socket, canonical), replace: true)
    end
  end

  defp canonical_scope_params(scope) do
    %{}
    |> put_param("service_id", scope.calendar && scope.calendar.service_id)
    |> put_param("direction", direction_param(scope.direction_id))
    |> put_param("pattern", scope.pattern_id)
  end

  defp put_param(query, _key, nil), do: query
  defp put_param(query, key, value), do: Map.put(query, key, value)

  defp direction_param(0), do: "0"
  defp direction_param(1), do: "1"
  defp direction_param(_direction), do: nil

  defp route_not_found(socket) do
    version_id = socket.assigns.current_gtfs_version.id

    socket
    |> put_flash(:error, "Route not found")
    |> push_navigate(to: "/gtfs/#{version_id}/routes")
  end

  defp switch_version(socket, version_id) do
    organization_id = socket.assigns.current_organization.id
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(organization_id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      query =
        case socket.assigns[:scope] do
          nil -> %{}
          scope -> canonical_scope_params(scope)
        end

      {:noreply,
       push_navigate(socket,
         to: paste_path_for(version_id, socket.assigns.route_id, query)
       )}
    else
      {:noreply, socket}
    end
  end

  defp paste_path(socket, query) do
    paste_path_for(socket.assigns.current_gtfs_version.id, socket.assigns.route_id, query)
  end

  defp paste_path_for(version_id, route_id, query) do
    path = "/gtfs/#{version_id}/routes/#{route_id}/schedules/paste"

    case URI.encode_query(query) do
      "" -> path
      encoded -> path <> "?" <> encoded
    end
  end

  # The blank paste input step 23's timetable step fills in: no text, no
  # overrides, confirmations or decisions, Add mode. `prepare_timetable_paste/5`
  # reviews it to `nil`, so the shell and the drawer render without a review
  # until the person pastes. `change_schedule` keeps the text and resets the
  # rest, so changing the schedule rebuilds the review from the same paste.
  defp fresh_paste_input do
    %{
      text: "",
      layout: :auto,
      header?: true,
      overrides: %{},
      confirmations: MapSet.new(),
      decisions: %{},
      mode: :add,
      template_timing_id: nil,
      stamp: "",
      block_rows: []
    }
  end

  defp input_text(socket) do
    case socket.assigns[:input] do
      %{text: text} when is_binary(text) -> text
      _input -> ""
    end
  end

  defp load_scope_calendars(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.list_calendars(organization_id, version_id) do
      {:ok, calendars} -> calendars
      {:error, _reason} -> []
    end
  end

  defp draft_params(scope) do
    %{
      "service_id" => scope.calendar && scope.calendar.service_id,
      "direction" => direction_param(scope.direction_id),
      "pattern" => scope.pattern_id
    }
  end

  defp string_params(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  # The draft scope backs the drawer's pattern options and trip counts. The
  # open reuses the loaded scope (a scope never depends on the input); a
  # calendar or direction change reloads it with an empty input, and a
  # pattern-only change keeps it. A failed reload keeps the previous options
  # rather than emptying the select; submitting still canonicalizes.
  defp refresh_draft_scope(socket, _current, draft) do
    draft_scope = socket.assigns.draft_scope

    if draft_scope == nil or draft_scope_stale?(draft_scope, draft) do
      case reload_draft_scope(socket, draft) do
        nil -> {draft, draft_scope}
        reloaded -> {fix_draft_pattern(draft, reloaded), reloaded}
      end
    else
      {draft, draft_scope}
    end
  end

  defp draft_scope_stale?(draft_scope, draft) do
    draft["service_id"] != draft_scope_service(draft_scope) or
      draft["direction"] != to_string(draft_scope.direction_id)
  end

  defp draft_scope_service(draft_scope) do
    draft_scope.calendar && draft_scope.calendar.service_id
  end

  defp reload_draft_scope(socket, draft) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    scope_params = %{
      service_id: present(draft["service_id"]),
      direction: present(draft["direction"])
    }

    case Gtfs.prepare_timetable_paste(
           organization_id,
           version_id,
           socket.assigns.route_id,
           scope_params,
           %{}
         ) do
      {:ok, %{scope: scope}} -> scope
      {:error, _reason} -> nil
    end
  end

  defp fix_draft_pattern(draft, draft_scope) do
    ids = Enum.map(draft_scope.patterns, & &1.id)

    if draft["pattern"] in ids do
      draft
    else
      Map.put(draft, "pattern", List.first(ids))
    end
  end

  defp schedule_query(params) do
    %{}
    |> put_param("service_id", present(params["service_id"] || params[:service_id]))
    |> put_param("direction", schedule_direction(params["direction"] || params[:direction]))
    |> put_param("pattern", present(params["pattern"] || params[:pattern]))
  end

  defp schedule_direction(direction) when direction in ["0", "1"], do: direction
  defp schedule_direction(_direction), do: nil

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value

  defp close_scope_drawer(socket) do
    socket
    |> assign(:scope_draft, nil)
    |> assign(:scope_form, to_form(%{}, as: :scope))
    |> assign(:draft_scope, nil)
  end

  defp chosen_pattern(%{patterns: patterns, pattern_id: pattern_id}) do
    Enum.find(patterns, &(&1.id == pattern_id))
  end

  defp setup_reason(%{calendar: nil}), do: :no_calendar
  defp setup_reason(%{patterns: []}), do: :no_pattern
  defp setup_reason(_scope), do: nil

  defp direction_name(0), do: "Outbound"
  defp direction_name(1), do: "Inbound"
  defp direction_name(_direction), do: "Outbound"

  defp direction_adjective(0), do: "outbound"
  defp direction_adjective(1), do: "inbound"
  defp direction_adjective(_direction), do: "outbound"
end
