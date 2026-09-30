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
  scope on the patch.

  Step 23 owns the timetable step: the `#paste-form` (`phx-change="input"`,
  `phx-submit="read"`) wraps `TimetablePasteComponents.source_step/1` and
  the columns/review placeholders steps 24-28 fill. The `input` event stashes
  the text, layout and header without touching the database; the `read` event
  re-resolves the scope through `Gtfs.prepare_timetable_paste/5` with the
  full current input. Parse failures keep the text and render the specific
  inline message; success collapses the step and auto-advances to the review
  placeholder when no column issues remain. The review UI (steps 25-28)
  builds on the `input`/`review` assigns kept here. The
  version-switch events mirror `RouteSchedulesLive`; the unsaved-work
  confirmation arrives in step 30.

  Step 24 owns the columns step: the Use-as selects post back into the
  `input` event as `paste[overrides][<col>]`, which is diffed against the
  review's effective values so untouched columns never pin their automatic
  pick; `confirm_column` records a close-match confirmation. Both recompute
  the review purely from the loaded scope through
  `TimetablePaste.review/2` (no database read); `to_review` with issues
  shows the error summary and focuses it.
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.RouteWorkspace, only: [route_header: 1, route_label: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.TimetablePaste
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
     |> assign(:paste_form, to_form(paste_form_params(), as: :paste))
     |> assign(:paste_error, nil)
     |> assign(:source_open, true)
     |> assign(:show_column_errors, false)
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

  # Step 23 owns the timetable step. Typing stashes the text, layout and
  # header into the input and rebuilds the form without touching the
  # database; only Read, Review again and Change schedule reload the scope
  # (review-recompute criterion). Clearing the textarea invalidates the last
  # read, so the stale review and error go away with it.
  # Step 24 extends the timetable step: the columns step's Use-as selects
  # arrive here as `paste[overrides][<col>]` alongside the text, layout and
  # header. Overrides are diffed against the review's effective values, so
  # re-submitting an untouched select never pins its automatic pick; a real
  # change recomputes the review purely from the loaded scope (no database
  # read) and advances to the review placeholder when the last issue
  # clears. Text, layout and header edits alone only stash, exactly like
  # step 23; clearing the textarea still invalidates the last read.
  @impl true
  def handle_event("input", %{"paste" => params}, socket) when is_map(params) do
    old_input = current_input(socket)
    input = merge_paste_params(old_input, params)
    input = merge_column_overrides(socket, old_input, input, params)

    socket =
      socket
      |> assign(:input, input)
      |> assign(:paste_form, to_form(paste_form_params(input), as: :paste))

    socket =
      cond do
        blank_paste_text?(input.text) ->
          socket
          |> assign(:review, nil)
          |> assign(:paste_error, nil)
          |> assign(:source_open, true)
          |> assign(:show_column_errors, false)

        recompute_columns?(socket, old_input, input, params) ->
          recompute_columns_review(socket, input)

        true ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("input", _params, socket), do: {:noreply, socket}

  # Reading re-resolves the scope through the facade with the full current
  # input (text, layout, header and whatever decisions/overrides later steps
  # add). A blank read names the empty fix; parse failures keep the text and
  # render the specific inline message; success collapses the step.
  @impl true
  def handle_event("read", params, socket) do
    paste_params =
      case params do
        %{"paste" => paste} when is_map(paste) -> paste
        _params -> %{}
      end

    input = merge_paste_params(current_input(socket), paste_params)

    socket =
      socket
      |> assign(:input, input)
      |> assign(:paste_form, to_form(paste_form_params(input), as: :paste))

    if blank_paste_text?(input.text) do
      {:noreply,
       socket
       |> assign(:review, nil)
       |> assign(:paste_error, :empty)
       |> assign(:source_open, true)}
    else
      {:noreply, read_paste(socket, input)}
    end
  end

  # Reopening keeps the text and the last review; the next Read replaces it.
  # A visible column error summary belongs to the columns stage, so it
  # goes away until the next Read or Review trips.
  @impl true
  def handle_event("edit_source", _params, socket) do
    {:noreply, socket |> assign(:source_open, true) |> assign(:show_column_errors, false)}
  end

  # Step 24 owns column confirmation: a close match joins the input's
  # confirmations and the review is recomputed purely from the loaded
  # scope. Confirming the last issue advances to the review placeholder
  # through the render conditions below.
  @impl true
  def handle_event("confirm_column", %{"col" => col}, socket) do
    with col when is_integer(col) <- parse_column(col),
         %{column_issues: [_ | _]} <- socket.assigns[:review] do
      input = current_input(socket)
      confirmations = MapSet.put(confirmation_set(input), col)
      input = %{input | confirmations: confirmations}

      {:noreply,
       socket
       |> assign(:input, input)
       |> assign(:paste_form, to_form(paste_form_params(input), as: :paste))
       |> recompute_columns_review(input)}
    else
      _unchanged -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_column", _params, socket), do: {:noreply, socket}

  # Review trips with column issues shows the error summary and focuses
  # it; with no issues the review placeholder is already showing.
  @impl true
  def handle_event("to_review", _params, socket) do
    case socket.assigns[:review] do
      %{column_issues: [_ | _]} ->
        {:noreply,
         socket
         |> assign(:show_column_errors, true)
         |> push_event("focus_scoped_target", %{id: "paste-column-errors"})}

      _review ->
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

          <.form
            :if={is_nil(setup_reason(@scope))}
            id="paste-form"
            for={@paste_form}
            phx-change="input"
            phx-submit="read"
            phx-hook="FormErrorFocus"
            class="mt-4 grid gap-4"
          >
            <TimetablePasteComponents.source_step
              form={@paste_form}
              error={@paste_error}
              open={@source_open}
              review={@review}
            />
            <TimetablePasteComponents.columns_step
              :if={@review != nil and !@source_open and @review.column_issues != []}
              review={@review}
              scope={@scope}
              header?={@input.header?}
              show_errors={@show_column_errors}
            />
            <TimetablePasteComponents.review_placeholder :if={
              @review != nil and !@source_open and @review.column_issues == []
            } />
          </.form>
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
      {:error, reason} -> apply_paste_error(socket, params, reason)
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
    |> assign(:paste_error, nil)
    |> assign(:source_open, is_nil(review))
    |> assign(:show_column_errors, false)
    |> assign(:load_state, :ready)
    |> push_canonical(scope, params)
  end

  # A parse failure is scope-independent, so the schedule line still
  # resolves: load the scope alone, then show the inline error with the text
  # kept. A blank input cannot fail the review, so any inner failure is the
  # missing route.
  defp apply_paste_error(socket, params, reason) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id

    case Gtfs.prepare_timetable_paste(
           organization_id,
           version_id,
           route_id,
           scope_params(params),
           %{}
         ) do
      {:ok, %{scope: scope}} ->
        socket
        |> assign(:route, scope.route)
        |> assign(:scope, scope)
        |> assign(:review, nil)
        |> assign(:paste_error, reason)
        |> assign(:source_open, true)
        |> assign(:load_state, :ready)
        |> push_canonical(scope, params)

      {:error, _reason} ->
        route_not_found(socket)
    end
  end

  # Reading re-resolves the current scope with the full input. Success
  # refreshes the scope and collapses the step; a parse failure keeps the
  # scope line and the text with the inline error.
  defp read_paste(socket, input) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id

    case Gtfs.prepare_timetable_paste(
           organization_id,
           version_id,
           route_id,
           read_scope_params(socket.assigns.scope),
           input
         ) do
      {:ok, %{scope: scope, review: nil}} ->
        socket
        |> assign(:route, scope.route)
        |> assign(:scope, scope)
        |> assign(:review, nil)
        |> assign(:paste_error, :empty)
        |> assign(:source_open, true)
        |> assign(:load_state, :ready)

      {:ok, %{scope: scope, review: review}} ->
        socket
        |> assign(:route, scope.route)
        |> assign(:scope, scope)
        |> assign(:review, review)
        |> assign(:paste_error, nil)
        |> assign(:source_open, false)
        |> assign(:show_column_errors, false)
        |> assign(:load_state, :ready)

      {:error, :not_found} ->
        route_not_found(socket)

      {:error, reason} ->
        socket
        |> assign(:review, nil)
        |> assign(:paste_error, reason)
        |> assign(:source_open, true)
    end
  end

  defp read_scope_params(nil), do: %{}

  defp read_scope_params(scope) do
    %{
      service_id: scope.calendar && scope.calendar.service_id,
      direction: direction_param(scope.direction_id),
      pattern: scope.pattern_id
    }
  end

  defp current_input(socket) do
    case socket.assigns[:input] do
      input when is_map(input) -> input
      _input -> fresh_paste_input()
    end
  end

  # Form params for the paste form. Only keys the form carries override the
  # input, so later steps' decisions/overrides ride along untouched.
  defp merge_paste_params(input, params) do
    %{
      input
      | text: paste_text(params, input),
        layout: paste_layout(params, input),
        header?: paste_header(params, input)
    }
  end

  defp paste_text(%{"text" => text}, _input) when is_binary(text), do: text
  defp paste_text(_params, input), do: input.text || ""

  defp paste_layout(%{"layout" => layout}, _input)
       when layout in ["auto", "trips_in_rows", "stops_in_rows"],
       do: String.to_atom(layout)

  defp paste_layout(_params, input), do: input.layout || :auto

  defp paste_header(%{"header" => header}, _input), do: header != "false"
  defp paste_header(_params, input), do: input.header? != false

  # Step 24 diffs the submitted Use-as selects against the current review's
  # effective values. A select re-submits its displayed pick whether or not
  # the person touched it, so storing every submission would pin each
  # automatic pick (and silently confirm every close match) into an
  # override. Only a real change writes or clears an override; anything
  # else leaves the input's overrides alone. Without a review there is
  # nothing to diff against, so the submitted selects are ignored (later
  # steps extend this branch for form recovery).
  defp merge_column_overrides(socket, old_input, input, params) do
    with %{"overrides" => submitted} when is_map(submitted) <- params,
         %{columns: columns} when is_list(columns) <- socket.assigns[:review] do
      %{input | overrides: diff_overrides(columns, old_input.overrides, submitted)}
    else
      _no_diff -> input
    end
  end

  defp diff_overrides(columns, current, submitted) do
    submitted = Map.new(submitted, fn {col, value} -> {to_string(col), value} end)
    current = current || %{}

    Enum.reduce(columns, current, fn column, acc ->
      case Map.fetch(submitted, Integer.to_string(column.col)) do
        :error ->
          acc

        {:ok, raw} ->
          value = raw |> to_string_safe() |> String.trim()
          effective = TimetablePasteComponents.column_value(column)

          if value == "" or value == effective do
            Map.delete(acc, column.col)
          else
            Map.put(acc, column.col, value)
          end
      end
    end)
  end

  # The review is recomputed only when the paste itself did not change:
  # an override edit with the same text, layout and header re-reviews the
  # loaded scope, while typing waits for Read like step 23.
  defp recompute_columns?(socket, old_input, input, params) do
    is_map(params["overrides"]) and input.text == old_input.text and
      input.layout == old_input.layout and input.header? == old_input.header? and
      not is_nil(socket.assigns[:scope]) and not is_nil(socket.assigns[:review])
  end

  # Recomputes the review purely from the loaded scope: the scope was
  # already read for the last Read or patch, so overrides and
  # confirmations never cost a database read. Overrides cannot break
  # parsing, so a failure keeps the last review. Clearing the last issue
  # hides a visible error summary with it.
  defp recompute_columns_review(socket, input) do
    case socket.assigns[:scope] do
      nil ->
        socket

      scope ->
        case TimetablePaste.review(scope, input) do
          {:ok, review} ->
            socket
            |> assign(:review, review)
            |> assign(
              :show_column_errors,
              socket.assigns[:show_column_errors] == true and review.column_issues != []
            )

          {:error, _reason} ->
            socket
        end
    end
  end

  defp confirmation_set(%{confirmations: %MapSet{} = confirmations}), do: confirmations
  defp confirmation_set(_input), do: MapSet.new()

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_safe(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_safe(_value), do: ""

  defp parse_column(col) when is_integer(col) and col >= 0, do: col

  defp parse_column(col) when is_binary(col) do
    case Integer.parse(String.trim(col)) do
      {number, ""} when number >= 0 -> number
      _parse -> nil
    end
  end

  defp parse_column(_col), do: nil

  defp paste_form_params(input \\ fresh_paste_input()) do
    %{
      "text" => input.text || "",
      "layout" => layout_param(input.layout),
      "header" => if(input.header? == false, do: "false", else: "true"),
      "overrides" =>
        Map.new(input.overrides || %{}, fn {col, value} -> {to_string(col), value} end)
    }
  end

  defp layout_param(:trips_in_rows), do: "trips_in_rows"
  defp layout_param(:stops_in_rows), do: "stops_in_rows"
  defp layout_param(_layout), do: "auto"

  defp blank_paste_text?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank_paste_text?(_text), do: true

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
