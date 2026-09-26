defmodule GtfsPlannerWeb.Gtfs.RoutePatternLive do
  @moduledoc """
  LiveView for the route pattern editor.

  It renders the route's Patterns list, the creation flow and the pattern
  Stops/Timings/Details tasks from the scoped `GtfsPlanner.Gtfs.RoutePatterns`
  reads. Every identifier used for a write comes from a loaded server record:
  the route and pattern are resolved from the URL inside the loaded
  organization/version scope, and a pattern or timing from another scope
  resolves to `not_found`. Access uses the existing editor guard, and a lost
  database connection renders as unavailable reading with an explicit retry.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.RoutePatternComponents

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @detail_fields ~w(name direction_id headsign time_desc typicality sort_order)
  @creation_defaults %{
    "name" => "",
    "direction_id" => "0",
    "headsign" => "",
    "time_desc" => "",
    "typicality" => "0",
    "sort_order" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Patterns")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:route, nil)
     |> assign(:route_id, nil)
     |> assign(:pattern_id, nil)
     |> assign(:loaded_pattern_id, :none)
     |> assign(:load_state, :loading)
     |> assign(:stale?, false)
     |> assign(:patterns_empty?, true)
     |> assign(:pattern_count, 0)
     |> assign(:route_trip_count, 0)
     |> assign(:pending_trip_count, 0)
     |> assign(:custom_trip_count, 0)
     |> assign(:derivation_error, nil)
     |> assign(:build_state, :idle)
     |> assign(:build_error, nil)
     |> assign(:task, :stops)
     |> assign(:pattern, nil)
     |> assign(:occurrences, [])
     |> assign(:stops, %{})
     |> assign(:stop_count, 0)
     |> assign(:detail_trip_count, 0)
     |> assign(:timings, [])
     |> assign(:selected_timing, nil)
     |> assign(:selected_timing_id, nil)
     |> assign(:selected_timing_rows, [])
     |> assign(:source_fingerprint, nil)
     |> assign(:timing_options, [])
     |> assign(:timing_form, to_form(%{}))
     |> assign(:stop_choices, [])
     |> assign(:stop_choice_form, to_form(%{"stop_id" => nil}))
     |> assign(:staged_stops, [])
     |> assign(:details_params, @creation_defaults)
     |> assign(:details_baseline, nil)
     |> assign(:details_form, details_form(@creation_defaults, []))
     |> assign(:dirty?, false)
     |> assign(:impact_dialog, nil)
     |> assign(:pending_navigation, nil)
     |> assign(:error_message, nil)
     |> assign(:status_message, nil)
     |> stream(:patterns, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action
    pattern_id = params["route_pattern_id"]
    timing_id = params["timing"]

    socket =
      socket
      |> assign(:route_id, params["route_id"])
      |> assign(:pattern_id, pattern_id)
      |> assign(:task, resolve_task(action, params["task"]))

    cond do
      not connected?(socket) ->
        {:noreply, assign(socket, :load_state, :loading)}

      reload_needed?(socket, pattern_id, timing_id) ->
        {:noreply, load_screen(socket, timing_id)}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reload_patterns", _params, socket) do
    {:noreply, load_screen(socket)}
  end

  @impl true
  def handle_event("build_patterns", _params, socket) do
    socket = assign(socket, :build_state, :building)

    result =
      Gtfs.build_route_patterns(socket.assigns.route_id, audit_context(socket))

    case result do
      {:ok, summary} ->
        {:noreply,
         socket
         |> assign(:build_state, :idle)
         |> put_build_summary(summary)
         |> load_screen()}

      {:error, :nothing_pending} ->
        {:noreply,
         socket
         |> assign(:build_state, :blocked)
         |> load_screen()}

      {:error, :not_found} ->
        {:noreply, not_found(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:build_state, :failed)
         |> assign(:build_error, build_error_message(reason))
         |> load_screen()}
    end
  end

  @impl true
  def handle_event("validate_details", %{"pattern" => params}, socket) do
    params = merge_details_params(socket.assigns.details_params, params)

    {:noreply,
     socket
     |> assign(:details_params, params)
     |> assign(:details_form, details_form(params, []))
     |> assign_dirty(details_dirty?(socket, params))}
  end

  def handle_event("validate_details", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_details", %{"pattern" => params}, socket) do
    params = merge_details_params(socket.assigns.details_params, params)

    case validate_details(params) do
      {:ok, attrs} ->
        socket
        |> assign(:details_params, params)
        |> assign(:details_form, details_form(params, []))
        |> review_details(attrs)

      {:error, errors, message} ->
        {:noreply, reject_details(socket, params, errors, message)}
    end
  end

  def handle_event("save_details", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("apply_details_review", _params, socket) do
    case socket.assigns.impact_dialog do
      %{attrs: attrs, fingerprint: fingerprint} ->
        socket
        |> assign(:impact_dialog, nil)
        |> apply_details(attrs, fingerprint)

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_details_review", _params, socket) do
    {:noreply, assign(socket, :impact_dialog, nil)}
  end

  @impl true
  def handle_event("create_pattern", params, socket) when is_map(params) do
    params =
      merge_details_params(socket.assigns.details_params, Map.get(params, "pattern", %{}))

    with :ok <- validate_creation_stops(socket.assigns.staged_stops),
         {:ok, attrs} <- validate_details(params) do
      attrs = Map.put(attrs, :stops, socket.assigns.staged_stops)

      case Gtfs.create_pattern(socket.assigns.route_id, attrs, audit_context(socket)) do
        {:ok, pattern} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Pattern created with its first timing. Set its running times next."
           )
           |> push_navigate(to: pattern_path(socket, pattern.route_pattern_id, "?task=timings"))}

        {:error, reason} ->
          {:noreply, reject_creation(socket, params, reason)}
      end
    else
      {:error, :at_least_two_stops} ->
        {:noreply, reject_creation(socket, params, :at_least_two_stops)}

      {:error, :adjacent_duplicate_stops} ->
        {:noreply, reject_creation(socket, params, :adjacent_duplicate_stops)}

      {:error, errors, message} ->
        {:noreply, reject_details(socket, params, errors, message)}
    end
  end

  def handle_event("create_pattern", _params, socket), do: {:noreply, socket}
  @impl true
  def handle_event("choose_stop", %{"stop_id" => stop_id}, socket) do
    socket = assign(socket, :stop_choice_form, to_form(%{"stop_id" => nil}))

    case Enum.find(socket.assigns.stop_choices, &(&1.stop_id == stop_id)) do
      nil ->
        {:noreply, assign(socket, :error_message, "Choose a stop from the list.")}

      stop ->
        adjacent = List.last(socket.assigns.staged_stops)

        if adjacent == stop.stop_id do
          {:noreply,
           assign(socket, :error_message, "This stop is already next to that position.")}
        else
          staged = socket.assigns.staged_stops ++ [stop.stop_id]

          {:noreply,
           socket
           |> assign(:staged_stops, staged)
           |> assign(:error_message, nil)
           |> assign_dirty(details_dirty?(socket, socket.assigns.details_params))}
        end
    end
  end

  def handle_event("choose_stop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("remove_stop", %{"index" => index}, socket) do
    case Integer.parse(to_string(index)) do
      {position, ""} ->
        staged = List.delete_at(socket.assigns.staged_stops, position - 1)

        {:noreply,
         socket
         |> assign(:staged_stops, staged)
         |> assign(:error_message, nil)
         |> assign_dirty(details_dirty?(socket, socket.assigns.details_params))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_task", %{"task" => task}, socket) do
    resolved = resolve_task(socket.assigns.live_action, task)

    {:noreply,
     socket
     |> assign(:task, resolved)
     |> assign(:error_message, nil)
     |> push_patch(to: task_path(socket, resolved))}
  end

  @impl true
  def handle_event("select_timing", %{"timing_id" => timing_id}, socket) do
    if timing_id == socket.assigns.selected_timing_id do
      {:noreply, socket}
    else
      {:noreply, load_screen(socket, timing_id)}
    end
  end

  def handle_event("select_timing", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_pattern", %{"pattern-id" => pattern_id}, socket) do
    guard_navigation(socket, pattern_path(socket, pattern_id, "?task=stops"))
  end

  @impl true
  def handle_event("back_to_patterns", _params, socket) do
    guard_navigation(socket, patterns_path(socket))
  end

  @impl true
  def handle_event("discard_changes", _params, socket) do
    case socket.assigns.pending_navigation do
      nil -> {:noreply, socket}
      path -> {:noreply, push_navigate(socket, to: path)}
    end
  end

  @impl true
  def handle_event("keep_editing", _params, socket) do
    {:noreply, assign(socket, :pending_navigation, nil)}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    handle_version_switch(socket, version_id)
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    handle_version_switch(socket, version_id)
  end

  defp handle_version_switch(socket, version_id) do
    organization_id = socket.assigns.current_organization.id
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(organization_id, version_id) do
      path =
        case socket.assigns.live_action do
          :new -> version_patterns_path(socket, version_id) <> "/new"
          :show -> version_pattern_path(socket, version_id)
          _ -> version_patterns_path(socket, version_id)
        end

      if socket.assigns.dirty? do
        {:noreply, assign(socket, :pending_navigation, path)}
      else
        socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
        {:noreply, push_navigate(socket, to: path)}
      end
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
      <:sub_header :if={@route}>
        <.route_sub_nav
          route={@route}
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={:patterns}
        />
      </:sub_header>

      <div
        id="pattern-editor"
        phx-hook="RoutePatternEditor"
        data-dirty={to_string(@dirty?)}
        class="mt-8"
      >
        <div id="pattern-editor-content" phx-hook="FormErrorFocus">
          <RoutePatternComponents.status_regions
            error={@error_message}
            status={@status_message}
          />

          <%= cond do %>
            <% @load_state == :loading -> %>
              <.skeleton id="patterns-loading" label="Loading patterns" rows={3} aria-busy="true" />
            <% @load_state == :unavailable -> %>
              <div id="patterns-unavailable" class="mt-2">
                <.callout kind="error" title="Patterns unavailable">
                  This route’s patterns could not be loaded. The rest of the app is unaffected.
                  <button
                    id="patterns-retry"
                    type="button"
                    phx-click="reload_patterns"
                    class="btn btn-sm btn-outline mt-2 min-h-11"
                  >
                    Retry
                  </button>
                </.callout>
              </div>
            <% @load_state == :ready and @live_action == :index -> %>
              <RoutePatternComponents.pattern_list_states
                patterns={@streams.patterns}
                patterns_empty?={@patterns_empty?}
                pattern_count={@pattern_count}
                route_trip_count={@route_trip_count}
                pending_trip_count={@pending_trip_count}
                custom_trip_count={@custom_trip_count}
                derivation_error={@derivation_error}
                build_state={@build_state}
                build_error={@build_error}
                stale?={@stale?}
                new_path={"/gtfs/#{@current_gtfs_version.id}/routes/#{@route_id}/patterns/new"}
              />
            <% @load_state == :ready -> %>
              <%= if @pattern || @live_action == :new do %>
                <RoutePatternComponents.pattern_detail_header
                  creating={@live_action == :new}
                  pattern_name={
                    if(@pattern,
                      do: @pattern.route_pattern_name || @pattern.route_pattern_id,
                      else: ""
                    )
                  }
                  direction_id={header_direction_id(assigns)}
                  stop_count={if @live_action == :new, do: length(@staged_stops), else: @stop_count}
                  trip_count={if @live_action == :new, do: 0, else: @detail_trip_count}
                  task={@task}
                  tasks={
                    if(@live_action == :new,
                      do: [:details, :stops],
                      else: [:stops, :timings, :details]
                    )
                  }
                  dirty?={@dirty?}
                  version_name={@current_gtfs_version.name}
                />

                <%= cond do %>
                  <% @task == :details -> %>
                    <RoutePatternComponents.details_task
                      form={@details_form}
                      submit_event={
                        if(@live_action == :new, do: "create_pattern", else: "save_details")
                      }
                      submit_label={
                        if(@live_action == :new, do: "Create pattern", else: "Save details")
                      }
                      pattern_id={if @pattern, do: @pattern.route_pattern_id, else: nil}
                      dirty?={@dirty?}
                    />
                  <% @task == :stops -> %>
                    <RoutePatternComponents.stops_task
                      creating={@live_action == :new}
                      occurrences={@occurrences}
                      stops={@stops}
                      staged_stops={@staged_stops}
                      stop_choices={@stop_choices}
                      stop_choice_form={@stop_choice_form}
                    />
                  <% true -> %>
                    <RoutePatternComponents.timings_task
                      timings={@timings}
                      selected_timing={@selected_timing}
                      selected_timing_rows={@selected_timing_rows}
                      timing_form={@timing_form}
                      timing_options={@timing_options}
                      stops={@stops}
                    />
                <% end %>
              <% else %>
                <div id="pattern-not-found" class="mt-2">
                  <.callout kind="error" title="Pattern not found">
                    This pattern does not belong to the selected route and version.
                  </.callout>
                </div>
              <% end %>
            <% true -> %>
              <div id="patterns-unavailable" class="mt-2">
                <.callout kind="error" title="Patterns unavailable">
                  This route’s patterns could not be loaded.
                </.callout>
              </div>
          <% end %>
        </div>

        <.confirm_dialog
          id="details-impact-dialog"
          open={@impact_dialog != nil}
          title={impact_title(@impact_dialog)}
          confirm_label="Update trips"
          pending_label="Updating…"
          on_confirm="apply_details_review"
          on_cancel="cancel_details_review"
          described_by="details-impact-dialog-body"
          confirm_variant="primary"
        >
          <p>
            Saving this pattern updates the trips below.
            <strong>This changes {@current_gtfs_version.name}, a published version.</strong>
          </p>
        </.confirm_dialog>

        <.confirm_dialog
          id="discard-changes-dialog"
          open={@pending_navigation != nil}
          title="Discard unsaved changes?"
          confirm_label="Discard changes"
          cancel_label="Keep editing"
          pending_label="Discarding…"
          on_confirm="discard_changes"
          on_cancel="keep_editing"
          described_by="discard-changes-dialog-body"
        >
          <p>
            Your unsaved changes were not saved. Keeping editing keeps them on this page.
          </p>
        </.confirm_dialog>
      </div>
    </Layouts.app>
    """
  end

  # --- loading ---------------------------------------------------------------

  defp reload_needed?(socket, pattern_id, timing_id) do
    socket.assigns.load_state != :ready or
      socket.assigns.loaded_pattern_id != pattern_id or
      (not is_nil(timing_id) and timing_id != socket.assigns.selected_timing_id)
  end

  defp load_screen(socket, timing_id \\ nil) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    route_id = socket.assigns.route_id

    opts = [
      pattern_id: socket.assigns.pattern_id,
      timing_id: timing_id || socket.assigns.selected_timing_id,
      include_stop_choices: socket.assigns.live_action == :new
    ]

    case Gtfs.load_route_pattern_screen(organization_id, version_id, route_id, opts) do
      {:ok, screen} -> apply_screen(socket, screen)
      {:error, :not_found} -> not_found(socket)
      {:error, :timing_not_found} -> timing_not_found(socket)
      {:error, :unavailable} -> unavailable(socket)
    end
  end

  # A timing outside the loaded pattern is refused without leaking the other
  # pattern's data, and the page falls back to the pattern's first timing.
  defp timing_not_found(socket) do
    socket
    |> assign(:error_message, "That timing is not part of this pattern.")
    |> assign(:selected_timing_id, nil)
    |> load_screen()
  end

  defp apply_screen(socket, screen) do
    previous_pattern_id = socket.assigns.loaded_pattern_id

    socket =
      socket
      |> assign(:route, screen.route)
      |> assign(:patterns_empty?, screen.patterns == [])
      |> assign(:pattern_count, length(screen.patterns))
      |> assign(
        :route_trip_count,
        screen.pending_trip_count + screen.custom_trip_count + screen.linked_trip_count
      )
      |> assign(:pending_trip_count, screen.pending_trip_count)
      |> assign(:custom_trip_count, screen.custom_trip_count)
      |> assign(:derivation_error, screen.derivation_error)
      |> assign(:stop_choices, screen.stop_choices)
      |> assign(:load_state, :ready)
      |> assign(:stale?, false)
      |> stream(:patterns, screen.patterns, reset: true)
      |> apply_detail(screen.detail, previous_pattern_id)

    assign_dirty(socket, details_dirty?(socket, socket.assigns.details_params))
  end

  defp apply_detail(socket, nil, _previous_pattern_id) do
    socket
    |> assign(:loaded_pattern_id, nil)
    |> assign(:pattern, nil)
    |> assign(:occurrences, [])
    |> assign(:stops, %{})
    |> assign(:stop_count, 0)
    |> assign(:detail_trip_count, 0)
    |> assign(:timings, [])
    |> assign(:selected_timing, nil)
    |> assign(:selected_timing_id, nil)
    |> assign(:selected_timing_rows, [])
    |> assign(:source_fingerprint, nil)
    |> assign(:timing_options, [])
  end

  defp apply_detail(socket, detail, previous_pattern_id) do
    pattern = detail.pattern
    selected = detail.selected_timing

    socket =
      socket
      |> assign(:loaded_pattern_id, pattern.route_pattern_id)
      |> assign(:pattern, pattern)
      |> assign(:occurrences, detail.occurrences)
      |> assign(:stops, detail.stops)
      |> assign(:stop_count, detail.stop_count)
      |> assign(:detail_trip_count, detail.trip_count)
      |> assign(:timings, detail.timings)
      |> assign(:selected_timing, selected)
      |> assign(:selected_timing_id, selected && selected.id)
      |> assign(:selected_timing_rows, detail.selected_timing_rows)
      |> assign(:source_fingerprint, detail.source_fingerprint)
      |> assign(:timing_options, timing_options(detail.timings))

    if previous_pattern_id == pattern.route_pattern_id do
      socket
    else
      params = details_params_from_pattern(pattern)
      put_details(socket, params, params)
    end
  end

  # A creation load never discards staged input: the page keeps whatever the
  # editor has already entered until the pattern is created.
  defp not_found(socket) do
    version_id = socket.assigns.current_gtfs_version.id

    case socket.assigns.live_action do
      :index ->
        socket
        |> put_flash(:error, "Route not found")
        |> push_navigate(to: "/gtfs/#{version_id}/routes")

      _ ->
        socket
        |> put_flash(:error, "Pattern not found")
        |> push_navigate(to: patterns_path(socket))
    end
  end

  defp unavailable(socket) do
    if socket.assigns.load_state == :ready do
      assign(socket, :stale?, true)
    else
      socket
      |> assign(:load_state, :unavailable)
      |> stream(:patterns, [], reset: true)
    end
  end

  # --- details ---------------------------------------------------------------

  defp review_details(socket, attrs) do
    attrs = changed_attrs(socket.assigns.pattern, attrs)

    if attrs == %{} do
      {:noreply, annotate(socket, "No changes to save.")}
    else
      submit_details_review(socket, attrs)
    end
  end

  defp submit_details_review(socket, attrs) do
    audit = audit_context(socket)

    case Gtfs.review(
           pattern_uuid(socket),
           {:details, attrs},
           socket.assigns.source_fingerprint,
           audit
         ) do
      {:ok, %{fingerprint: fingerprint, impact: %{trips_affected: affected}}} when affected > 0 ->
        {:noreply,
         assign(socket, :impact_dialog, %{
           attrs: attrs,
           fingerprint: fingerprint,
           trips_affected: affected
         })}

      {:ok, %{fingerprint: fingerprint}} ->
        apply_details(socket, attrs, fingerprint)

      {:error, reason} ->
        {:noreply, assign(socket, :error_message, reasons_message(reason))}
    end
  end

  # Only attributes that differ from the loaded pattern are submitted, so an
  # unchanged direction never asks for an impact review and the review
  # fingerprint describes the change the user actually made.
  defp changed_attrs(%RoutePattern{} = pattern, attrs) do
    attrs
    |> Enum.reject(fn {field, value} -> Map.get(pattern, field) == value end)
    |> Map.new()
  end

  defp changed_attrs(_pattern, attrs), do: attrs

  defp apply_details(socket, attrs, fingerprint) do
    audit = audit_context(socket)

    case Gtfs.apply_review(pattern_uuid(socket), {:details, attrs}, fingerprint, audit) do
      {:ok, %{trips_updated: updated}} ->
        {:noreply,
         socket
         |> put_details(socket.assigns.details_params, socket.assigns.details_params)
         |> annotate(affected_message(updated))
         |> load_screen()}

      {:error, reason} ->
        {:noreply, assign(socket, :error_message, reasons_message(reason))}
    end
  end

  defp reject_details(socket, params, errors, message) do
    socket
    |> assign(:details_params, params)
    |> assign(:details_form, details_form(params, errors))
    |> assign(:error_message, message)
    |> assign(:task, :details)
    |> push_event("focus_form_error", %{form_id: "pattern-details-form", fallback_id: nil})
  end

  defp reject_creation(socket, params, reason) do
    {errors, message} = creation_rejection(reason)

    socket
    |> assign(:details_params, params)
    |> assign(:details_form, details_form(params, errors))
    |> assign(:error_message, message)
    |> assign(:task, if(reason == :at_least_two_stops, do: :stops, else: :details))
    |> push_event("focus_form_error", %{form_id: "pattern-details-form", fallback_id: nil})
  end

  defp creation_rejection(:at_least_two_stops) do
    {[], "Add at least two stops before creating the pattern."}
  end

  defp creation_rejection(:adjacent_duplicate_stops) do
    {[], "This stop is already next to that position. Remove one of them."}
  end

  defp creation_rejection(:invalid_input) do
    {[], "The submitted values could not be saved. Check the form and try again."}
  end

  defp creation_rejection(%Ecto.Changeset{} = changeset) do
    {changeset_errors(changeset), changeset_message(changeset)}
  end

  defp creation_rejection(other), do: {[], reasons_message(other)}

  defp merge_details_params(current, incoming) when is_map(incoming) do
    Enum.reduce(@detail_fields, current, fn field, acc ->
      case Map.fetch(incoming, field) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp merge_details_params(current, _incoming), do: current

  defp validate_details(params) do
    with {:ok, name} <- require_name(params),
         {:ok, direction_id} <- parse_direction(params),
         {:ok, typicality} <- parse_typicality(params),
         {:ok, order} <- parse_sort_order(params) do
      {:ok,
       %{
         route_pattern_name: name,
         direction_id: direction_id,
         headsign: blank_to_nil(params["headsign"]),
         route_pattern_time_desc: blank_to_nil(params["time_desc"]),
         route_pattern_typicality: typicality,
         route_pattern_sort_order: order
       }}
    else
      {:error, field, message} -> {:error, [{field, message}], message}
    end
  end

  defp require_name(params) do
    case params["name"] do
      name when is_binary(name) ->
        if String.trim(name) == "",
          do: {:error, :name, "Enter a pattern name."},
          else: {:ok, String.trim(name)}

      _ ->
        {:error, :name, "Enter a pattern name."}
    end
  end

  defp parse_direction(params) do
    case params["direction_id"] do
      "0" -> {:ok, 0}
      "1" -> {:ok, 1}
      0 -> {:ok, 0}
      1 -> {:ok, 1}
      _ -> {:error, :direction_id, "Choose direction 0 or direction 1."}
    end
  end

  defp parse_typicality(params) do
    case params["typicality"] do
      value when value in ["0", "1", "2", "3", "4", "5"] -> {:ok, String.to_integer(value)}
      value when value in [0, 1, 2, 3, 4, 5] -> {:ok, value}
      _ -> {:error, :typicality, "Choose a use on this route from the list."}
    end
  end

  defp parse_sort_order(params) do
    case params["sort_order"] do
      value when value in [nil, ""] ->
        {:ok, nil}

      value ->
        case to_string(value) |> Integer.parse() do
          {order, ""} when order >= 0 -> {:ok, order}
          _ -> {:error, :sort_order, "Use a whole number of zero or more."}
        end
    end
  end

  defp validate_creation_stops(stops) do
    cond do
      length(stops) < 2 ->
        {:error, :at_least_two_stops}

      Enum.any?(Enum.chunk_every(stops, 2, 1, :discard), fn [a, b] -> a == b end) ->
        {:error, :adjacent_duplicate_stops}

      true ->
        :ok
    end
  end

  defp details_params_from_pattern(pattern) do
    %{
      "name" => pattern.route_pattern_name || "",
      "direction_id" => to_string(pattern.direction_id),
      "headsign" => pattern.headsign || "",
      "time_desc" => pattern.route_pattern_time_desc || "",
      "typicality" => to_string(pattern.route_pattern_typicality || 0),
      "sort_order" =>
        if(is_nil(pattern.route_pattern_sort_order),
          do: "",
          else: to_string(pattern.route_pattern_sort_order)
        )
    }
  end

  defp put_details(socket, params, baseline) do
    socket
    |> assign(:details_params, params)
    |> assign(:details_baseline, baseline)
    |> assign(:details_form, details_form(params, []))
    |> assign_dirty(baseline != nil and params != baseline)
  end

  defp details_form(params, errors) do
    to_form(params, as: :pattern, errors: errors)
  end

  defp details_dirty?(socket, params) do
    case {socket.assigns.live_action, socket.assigns.details_baseline} do
      {:new, _baseline} -> params != @creation_defaults or socket.assigns.staged_stops != []
      {_action, nil} -> false
      {_action, baseline} -> params != baseline
    end
  end

  defp assign_dirty(socket, dirty?) do
    dirty? = dirty? == true

    if socket.assigns.dirty? == dirty? do
      socket
    else
      push_event(assign(socket, :dirty?, dirty?), "route_pattern_dirty", %{dirty: dirty?})
    end
  end

  # --- navigation and helpers ------------------------------------------------

  # Review and apply take the pattern's database identity, which always comes
  # from the loaded server record rather than from the browser.
  defp pattern_uuid(socket), do: socket.assigns.pattern && socket.assigns.pattern.id

  defp guard_navigation(socket, path) do
    if socket.assigns.dirty? do
      {:noreply, assign(socket, :pending_navigation, path)}
    else
      {:noreply, push_navigate(socket, to: path)}
    end
  end

  defp resolve_task(:new, "stops"), do: :stops
  defp resolve_task(:new, _task), do: :details
  defp resolve_task(_action, "timings"), do: :timings
  defp resolve_task(_action, "details"), do: :details
  defp resolve_task(_action, "stops"), do: :stops
  defp resolve_task(_action, _task), do: :stops

  defp timing_options(timings) do
    Enum.map(timings, fn %{timing: timing, trip_count: trip_count} ->
      {timing_option_label(timing.name, trip_count), timing.id}
    end)
  end

  defp timing_option_label(name, 1), do: "#{name} · 1 trip"
  defp timing_option_label(name, count), do: "#{name} · #{count} trips"

  defp header_direction_id(assigns) do
    case assigns.pattern do
      %{direction_id: direction_id} -> direction_id
      nil -> header_creation_direction(assigns.details_params["direction_id"])
    end
  end

  defp header_creation_direction("1"), do: 1
  defp header_creation_direction(_value), do: 0

  defp patterns_path(socket) do
    "/gtfs/#{socket.assigns.current_gtfs_version.id}/routes/#{socket.assigns.route_id}/patterns"
  end

  defp version_patterns_path(socket, version_id) do
    "/gtfs/#{version_id}/routes/#{socket.assigns.route_id}/patterns"
  end

  defp version_pattern_path(socket, version_id) do
    "#{version_patterns_path(socket, version_id)}/#{socket.assigns.pattern_id}" <>
      task_query(socket)
  end

  defp pattern_path(socket, pattern_id, query) do
    "/gtfs/#{socket.assigns.current_gtfs_version.id}/routes/#{socket.assigns.route_id}/patterns/#{pattern_id}#{query}"
  end

  defp task_path(socket, task) do
    base =
      case socket.assigns.live_action do
        :new -> "#{patterns_path(socket)}/new"
        _ -> "#{patterns_path(socket)}/#{socket.assigns.pattern_id}"
      end

    "#{base}?#{task_query(socket, task)}"
  end

  defp task_query(socket, task \\ nil) do
    task = task || socket.assigns.task

    case socket.assigns.selected_timing_id do
      nil -> "task=#{task}"
      timing_id -> "task=#{task}&timing=#{timing_id}"
    end
  end

  defp audit_context(socket) do
    %AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      station_stop_id: nil,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end

  defp annotate(socket, message), do: assign(socket, :status_message, message)

  defp put_build_summary(socket, summary) do
    created = Map.get(summary, :patterns_created, 0)
    linked = Map.get(summary, :trips_linked, 0)
    custom = Map.get(summary, :trips_custom, 0)

    annotate(
      socket,
      "Patterns built from existing trips: #{created} patterns created, " <>
        "#{linked} trips linked, #{custom} kept as custom."
    )
  end

  defp affected_message(0), do: "Changes saved in this version."

  defp affected_message(updated),
    do: "Changes saved in this version. #{updated} trips updated."

  defp impact_title(%{trips_affected: affected}), do: "Update #{affected} trips?"
  defp impact_title(_dialog), do: "Update trips?"

  defp build_error_message(:not_found), do: "This route is no longer available."

  defp build_error_message(reason),
    do: "Building patterns failed (#{bounded_reason(reason)}). No trips were changed."

  defp bounded_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp bounded_reason(reason) when is_binary(reason), do: reason
  defp bounded_reason(_reason), do: "unexpected_error"

  defp reasons_message(:not_found), do: "That pattern is no longer available."

  defp reasons_message(:stale_review),
    do: "This pattern changed since the page loaded. Reload the pattern and try again."

  defp reasons_message(:invalid_input),
    do: "The submitted values could not be saved. Check the form and try again."

  defp reasons_message(:pattern_in_use), do: "Trips still use this pattern."
  defp reasons_message(:timing_in_use), do: "Trips still use this timing."
  defp reasons_message(:last_timing), do: "A pattern keeps at least one timing."

  defp reasons_message(%Ecto.Changeset{} = changeset), do: changeset_message(changeset)

  defp reasons_message(:unavailable),
    do: "The data store is temporarily unavailable. Your edits are still here."

  defp reasons_message(_reason),
    do: "The change could not be saved. Your edits are still here."

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map(fn {field, [message | _]} -> {field, message} end)
  end

  defp changeset_message(changeset) do
    case changeset_errors(changeset) do
      [{_field, message} | _] -> "The change could not be saved: #{message}."
      [] -> "The change could not be saved. Check the form and try again."
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
