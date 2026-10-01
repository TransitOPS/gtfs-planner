defmodule GtfsPlannerWeb.Gtfs.CalendarsLive do
  @moduledoc """
  Listing surface for the editable service calendars of one published version.

  The list is a read-only view over the scoped union read model: identities come
  from the weekly, exception and metadata tables through
  `Gtfs.load_calendar_screen/3`, one protected snapshot that also carries the
  agency-local date, the version-wide horizon and gaps, and every row's derived
  periods, exceptions and grouped trip usage. The "When it runs" column draws each
  row's effective dates on one shared axis (`GtfsPlannerWeb.Gtfs.CalendarCoverage`),
  so two calendars can be compared instead of only being described. Search, status,
  sort and the timeline range are URL state with allowlists, so reload and back
  navigation reproduce the list.

  States stay distinct: the first paint of a slow load renders the skeleton, a
  failed read renders the retry callout (never an empty list), an explicit refresh
  keeps the loaded rows while it reports progress, only a successful read with
  no identities renders the first-use empty state, and a version holding an
  unreadable imported range keeps its valid rows while the repair callout names the
  identity and the read asserts no complete gap set (AC-5).

  The cross-calendar drawer changes the service on one date, a range or several
  selected dates for more than one calendar at once. It keeps one source snapshot
  per opened drawer, so every selected service carries the fingerprint loaded with
  the list that supplied it, and the atomic `{:date_change, dates, remove_from,
  add_to}` command is reviewed before anything is written. Removal defaults are the
  calendars running on at least one selected date and are recomputed as the dates
  change until the reviewer customizes them.

  Requires pathways_studio_editor, the same guard as the route and stop catalogs.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.PlannerComponents,
    only: [drawer_footer: 1, drawer_scroll: 1, first_use: 1, message: 1]

  import GtfsPlannerWeb.AgentComponents, only: [agent_panel: 1]

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Calendars.Combination
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.AgentPanel
  alias GtfsPlannerWeb.Gtfs.CalendarComponents
  alias GtfsPlannerWeb.Gtfs.CalendarCoverage
  alias GtfsPlannerWeb.Gtfs.CalendarEditorComponents, as: Editor

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @status_options [
    {"All calendars", "all"},
    {"In service period", "active_period"},
    {"Running today", "active_today"},
    {"Ending within 14 days", "ends_soon"},
    {"Ended", "ended"},
    {"Not used by trips", "unused"}
  ]
  @status_keys Enum.map(@status_options, &elem(&1, 1))
  @date_change_modes [
    {"One date", "single"},
    {"Date range", "range"},
    {"Several dates", "several"}
  ]
  @date_change_mode_keys Enum.map(@date_change_modes, &elem(&1, 1))
  @sort_keys ~w(name period)
  @combine_decision_values ~w(run no_service)
  @sort_dirs ~w(asc desc)
  @range_keys ~w(whole near all)
  @range_options [
    %{value: "whole", label: "All dates"},
    %{value: "near", label: "Next 3 months"}
  ]
  @prepared_missing_notice "One of these calendars is no longer in this service version. Refresh the list and ask again."
  @prepared_edited_notice "Your edited change was saved. The original prepared change was not applied."
  @extension_missing_notice "That extension cannot be reviewed from this page. Ask the helper to prepare it again."
  @max_approval_length 2_000
  @max_extension_days 366

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Calendars")
     |> assign(:status_options, @status_options)
     |> assign(:range_options, @range_options)
     |> assign(:calendars_state, :loading)
     |> assign(:all_calendars, [])
     |> assign(:calendars, [])
     |> assign(:counts, %{calendars: 0, run_today: 0, ending_soon: 0})
     |> assign(:zone, nil)
     |> assign(:today, nil)
     |> assign(:gaps, [])
     |> assign(:screen, nil)
     |> assign(:coverage, nil)
     |> assign(:coverage_detail, nil)
     |> assign(:coverage_return_focus, nil)
     |> assign(:invalid_calendars, [])
     |> assign(:long_history?, false)
     |> assign(:calendars_empty?, false)
     |> assign(:filtered_empty?, false)
     |> assign(:constraints?, false)
     |> assign(:search, "")
     |> assign(:status, "all")
     |> assign(:range, "whole")
     |> assign(:sort_by, "name")
     |> assign(:sort_dir, "asc")
     |> assign(:date_change_status, nil)
     |> assign(:date_change_modes, @date_change_modes)
     |> assign(:date_change_mode, "single")
     |> assign(:date_change_return_focus, "calendar-date-change")
     |> assign(:selected_service_ids, MapSet.new())
     |> assign(:selection_version_id, nil)
     |> assign(:combine_open?, false)
     |> assign(:combine_error, nil)
     |> assign(:combine_generation, 0)
     |> assign(:combine_success, nil)
     |> assign(:combine_highlight, MapSet.new())
     |> assign(:combine_return_focus_id, nil)
     |> assign(:combine_dispatched?, false)
     |> assign_filter_form()
     |> open_extension_approval()
     |> drop_combination()
     |> close_date_change()
     |> stream_configure(:calendars, dom_id: &"calendar-#{URI.encode_www_form(&1.service_id)}")
     |> stream(:calendars, [])
     |> AgentPanel.mount("calendars")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> clear_selection_for_version()
      |> assign(:search, params["search"] || "")
      |> assign(:status, allowlisted(params["status"], @status_keys, "all"))
      |> assign(:range, allowlisted(params["range"], @range_keys, "whole"))
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

  # The reviewed apply runs in the LiveView's own async task: the socket renders its pending state
  # before the task starts, keeps its audit/scope in the task's closure, and settles exactly once
  # per dispatched confirmation.
  @impl true
  def handle_async({:combine_apply, generation}, result, socket) do
    if generation == socket.assigns.combine_generation do
      {:noreply, settle_combination(socket, result)}
    else
      # A result of a superseded review, or of a version the reviewer left, is presentation only:
      # it never rewrites the drawer on screen, and it makes no claim about the transaction that
      # produced it - a committed operation is never described as cancelled here.
      {:noreply, socket}
    end
  end

  def handle_async({:extension_apply, generation}, result, socket) do
    if generation == socket.assigns.extension_generation do
      {:noreply, settle_extension(socket, result)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filters", params, socket) do
    {:noreply,
     push_patch(socket, to: calendars_path(socket.assigns, to_query(socket.assigns, params)))}
  end

  @impl true
  def handle_event("sort", %{"key" => key}, socket) do
    sort_by = allowlisted(key, @sort_keys, "name")
    sort_dir = next_sort_dir(socket.assigns.sort_by, socket.assigns.sort_dir, sort_by)

    {:noreply,
     push_patch(socket,
       to: calendars_path(socket.assigns, to_query(socket.assigns, %{}, sort_by, sort_dir))
     )}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: calendars_path(socket.assigns, %{}))}
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
      {:noreply, push_navigate(socket, to: calendars_path(socket.assigns, %{}, version_id))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: calendars_path(socket.assigns, %{}, version_id))}
    else
      {:noreply, socket}
    end
  end

  ## Coverage details inspector

  @impl true
  def handle_event("open_coverage_details", %{"service-id" => service_id}, socket) do
    {:noreply, open_coverage_details(socket, service_id)}
  end

  @impl true
  def handle_event("close_coverage_details", _params, socket) do
    {:noreply, assign(socket, :coverage_detail, nil)}
  end

  ## Date-change drawer

  @impl true
  def handle_event("open_date_change", params, socket) do
    {:noreply, open_date_change(socket, params["date"])}
  end

  @impl true
  def handle_event(
        "close_date_change",
        _params,
        %{assigns: %{date_change_pending?: true}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("close_date_change", _params, socket) do
    {:noreply, close_date_change(socket)}
  end

  @impl true
  def handle_event("date_change_refresh", _params, socket) do
    case Gtfs.load_calendar_catalog(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           []
         ) do
      {:ok, summaries} ->
        sources = snapshot_sources(summaries)
        ids = MapSet.new(Map.keys(sources))

        {:noreply,
         socket
         |> assign(:all_calendars, summaries)
         |> assign(:date_change_sources, sources)
         |> assign(
           :date_change_remove,
           MapSet.intersection(socket.assigns.date_change_remove, ids)
         )
         |> assign(:date_change_add, MapSet.intersection(socket.assigns.date_change_add, ids))
         |> put_date_change_dates(socket.assigns.date_change_dates)}

      {:error, _reason} ->
        {:noreply,
         date_change_error(socket, "targets", "The snapshot could not be refreshed. Try again.")}
    end
  end

  @impl true
  def handle_event("date_change_form", params, socket) do
    {:noreply, update_date_change_dates(socket, date_change_params(params))}
  end

  @impl true
  def handle_event("date_change_add_date", params, socket) do
    params = date_change_params(params)

    if socket.assigns.date_change_mode == "several" do
      {:noreply, add_date_change_date(socket, params)}
    else
      {:noreply, review_date_change(socket)}
    end
  end

  @impl true
  def handle_event("date_change_remove_date", %{"date" => iso}, socket) do
    case parse_date(iso) do
      {:ok, date} ->
        {:noreply,
         put_date_change_dates(socket, List.delete(socket.assigns.date_change_dates, date))}

      :error ->
        {:noreply, date_change_error(socket, "date_add", "That date could not be read.")}
    end
  end

  @impl true
  def handle_event("date_change_toggle", %{"group" => group, "service-id" => service_id}, socket) do
    {:noreply, toggle_date_change_target(socket, group, service_id)}
  end

  @impl true
  def handle_event("date_change_review", _params, socket) do
    {:noreply, review_date_change(socket)}
  end

  @impl true
  def handle_event("date_change_apply", _params, socket) do
    {:noreply, apply_date_change(socket)}
  end

  @impl true
  def handle_event("date_change_back", _params, socket) do
    {:noreply, assign(socket, :date_change_review, nil)}
  end

  # The prepared card hands its proposal to this page's own drawer: the session
  # releases the proposal and only this drawer's reviewed apply can write (INV-3).
  # Every identity involved is server-held; the client contributes the entry id.
  @impl true
  def handle_event("agent_review_prepared", %{"entry" => id}, socket) do
    {:noreply, review_prepared_change(socket, id)}
  end

  def handle_event("agent_review_prepared", _params, socket), do: {:noreply, socket}

  ## Approved calendar extension

  # The approval is the editor's own words in this page's form. It is validated
  # here and copied into the helper session's resource context, which is the only
  # place a pack tool can read it from (INV-4): the model never supplies it, and
  # nothing is written here.
  @impl true
  def handle_event("extension_approval_change", params, socket) do
    {:noreply,
     socket
     |> assign(:extension_form, extension_form(extension_params(params)))
     |> assign(:extension_errors, %{})
     |> assign(:extension_notice, nil)}
  end

  @impl true
  def handle_event("extension_approval", params, socket) do
    {:noreply, approve_extension(socket, extension_params(params))}
  end

  # The reviewer's end date is a native value: changing it re-runs the same review
  # and produces a different command, which is then an edited native change rather
  # than the helper's exact one (AC-16).
  @impl true
  def handle_event("extension_review_change", params, socket) do
    {:noreply, change_extension_end_date(socket, extension_review_params(params))}
  end

  @impl true
  def handle_event("extension_review", _params, socket) do
    {:noreply, review_extension(socket)}
  end

  # A second confirmation while the first is in flight is refused, exactly as for
  # the date change: the reviewed token is already being applied.
  @impl true
  def handle_event("extension_apply", _params, %{assigns: %{extension_pending?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("extension_apply", _params, socket), do: {:noreply, dispatch_extension(socket)}

  @impl true
  def handle_event("extension_close", _params, socket), do: {:noreply, close_extension(socket)}

  @impl true
  def handle_event("extension_refresh", _params, socket) do
    socket = review_extension(socket)

    {:noreply, socket |> assign(:extension_refresh_required?, false) |> reload_calendars()}
  end

  # The transport hook reports a reconnection. This socket never learns that a
  # connection dropped, so it is the only place a confirmation whose answer was
  # lost can be resolved: the current state is re-read and nothing is resent.
  @impl true
  def handle_event("extension_reconnect", _params, socket) do
    {:noreply, reconnect_extension(socket)}
  end

  ## Selection and calendar combination

  @impl true
  def handle_event("toggle_calendar_selection", %{"service-id" => service_id}, socket)
      when is_binary(service_id) do
    {:noreply, toggle_calendar_selection(socket, service_id)}
  end

  def handle_event("toggle_calendar_selection", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_all_calendars", _params, socket) do
    ids = selectable_calendars(socket) |> Enum.map(& &1.service_id) |> MapSet.new()

    # The control is the header checkbox of the list: checking it selects every matching
    # selectable row, and unchecking it - which is what it reads as once every row is
    # already selected - clears the selection.
    selected =
      if MapSet.size(ids) > 0 and not MapSet.equal?(ids, socket.assigns.selected_service_ids) do
        ids
      else
        MapSet.new()
      end

    {:noreply,
     socket
     |> assign(:selected_service_ids, selected)
     |> drop_combination()
     |> restream_calendars(socket.assigns.calendars)}
  end

  @impl true
  def handle_event("clear_calendar_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_service_ids, MapSet.new())
     |> drop_combination()
     |> restream_calendars(socket.assigns.calendars)}
  end

  @impl true
  def handle_event("open_combine", _params, socket) do
    {:noreply, open_combine(socket)}
  end

  @impl true
  def handle_event("close_combine", _params, %{assigns: %{combine_pending?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("close_combine", _params, socket), do: {:noreply, drop_combination(socket)}

  @impl true
  def handle_event(
        "combine_change",
        %{"combine" => %{"destination_id" => destination_id} = params},
        socket
      )
      when is_binary(destination_id) do
    {:noreply, change_combination(socket, destination_id, submitted_decisions(params))}
  end

  def handle_event("combine_change", _params, socket), do: {:noreply, socket}

  # A second confirmation while the first is in flight is refused: the reviewer's one reviewed
  # token is already being applied, and a duplicate would either repeat a committed operation or
  # race the same rows. The same clause refuses the older "combine_destination" field event.
  @impl true
  def handle_event("combine_apply", _params, %{assigns: %{combine_pending?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("combine_apply", _params, socket) do
    {:noreply, apply_combination(socket)}
  end

  @impl true
  def handle_event("combine_refresh", _params, %{assigns: %{combine_pending?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("combine_refresh", _params, socket) do
    {:noreply, refresh_combination(socket)}
  end

  # The transport hook reports a reconnection. The socket never knows a disconnect happened, so
  # this is the only place the page can resolve what a lost confirmation did: it re-reads the
  # authoritative list and leaves the reviewer a fresh review instead of resending the old command.
  @impl true
  def handle_event("combine_reconnect", _params, socket) do
    {:noreply, reconnect_combination(socket)}
  end

  @impl true
  # Dismissing the summary removes the focused control, so focus is handed to the list's own
  # selection action instead of being left on the document (AC-24). The list is a stream, so
  # clearing the highlight only reaches the rendered rows when they are re-sent: without this the
  # tint would outlive the summary it explains.
  def handle_event("dismiss_combine_success", _params, socket) do
    {:noreply,
     socket
     |> assign(:combine_success, nil)
     |> assign(:combine_highlight, MapSet.new())
     |> restream_calendars(socket.assigns.calendars)
     |> push_event("calendar:combine-focus", %{
       id: "calendar-select-all",
       fallback_id: "calendar-search"
     })}
  end

  @impl true
  def handle_event(
        "combine_destination",
        %{"combine" => %{"destination_id" => destination_id}},
        socket
      )
      when is_binary(destination_id) do
    {:noreply, change_combination(socket, destination_id, %{})}
  end

  def handle_event("combine_destination", _params, socket), do: {:noreply, socket}

  ## Data loading

  defp load_calendars(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    opts = [
      sort_by: String.to_existing_atom(socket.assigns.sort_by),
      sort_dir: String.to_existing_atom(socket.assigns.sort_dir)
    ]

    case Gtfs.load_calendar_screen(organization_id, version_id, opts) do
      {:ok, screen} ->
        socket
        |> assign(:screen, screen)
        |> assign(:all_calendars, screen.rows)
        |> assign(:zone, screen.zone)
        |> assign(:today, screen.today)
        |> assign(:gaps, screen.gaps)
        |> assign(:invalid_calendars, screen.invalid_calendars)
        |> assign(:long_history?, CalendarCoverage.long_history?(screen))
        |> assign_coverage()
        |> assign(:calendars_state, :ready)
        |> assign_rows()
        |> note_hidden_combination_sources()

      {:error, :unavailable} ->
        unavailable(socket)

      {:error, :not_found} ->
        socket
        |> assign(:calendars_state, :not_found)
        |> assign(:all_calendars, [])
        |> assign(:calendars, [])
        |> assign(:calendars_empty?, false)
        |> assign(:filtered_empty?, false)
        |> clear_coverage()
        |> stream(:calendars, [], reset: true)
    end
  end

  # A closed inspector keeps the read's projection in step with the list, so it drops its
  # snapshot as soon as the screen is re-read: a range, filter, sort, refresh or version
  # change shows dates from the read it was opened against, never a stale axis.
  defp assign_coverage(socket) do
    socket
    |> assign(:coverage_detail, nil)
    |> assign(
      :coverage,
      CalendarCoverage.project(socket.assigns.screen, range_atom(socket.assigns.range))
    )
  end

  defp open_coverage_details(socket, service_id) do
    with %{} = row <- Enum.find(socket.assigns.all_calendars, &(&1.service_id == service_id)),
         true <- is_nil(row.coverage_error),
         %{} = projection <- socket.assigns.coverage do
      socket
      |> assign(:coverage_detail, coverage_detail(projection, row, socket.assigns.today))
      |> assign(:coverage_return_focus, CalendarComponents.coverage_control_id(service_id))
    else
      _unavailable -> socket
    end
  end

  defp coverage_detail(projection, row, today) do
    outside = CalendarCoverage.dates_outside(projection, row)

    %{
      row: row,
      coverage: Map.get(projection.rows, row.service_id, %{marks: [], offscreen: nil}),
      window: coverage_window(projection),
      before: outside.before,
      after: outside.after,
      today: today,
      regular_days: CalendarComponents.regular_days(row)
    }
  end

  defp coverage_window(%{first_date: nil}), do: nil

  defp coverage_window(%{first_date: first_date, last_date: last_date}),
    do: %{first_date: first_date, last_date: last_date}

  defp coverage_details_title(%{coverage_detail: nil}), do: "Service dates"
  defp coverage_details_title(%{coverage_detail: %{row: row}}), do: row.name || row.service_id

  defp range_atom("near"), do: :near
  defp range_atom("all"), do: :all
  defp range_atom(_range), do: :whole

  # A failed read is never an empty list: the rows and their counts are dropped
  # and the retry callout takes their place.
  defp unavailable(socket) do
    socket
    |> assign(:calendars_state, :unavailable)
    |> assign(:all_calendars, [])
    |> assign(:calendars, [])
    |> assign(:calendars_empty?, false)
    |> assign(:filtered_empty?, false)
    |> assign(:zone, nil)
    |> assign(:today, nil)
    |> assign(:gaps, [])
    |> clear_coverage()
    |> stream(:calendars, [], reset: true)
  end

  defp clear_coverage(socket) do
    socket
    |> assign(:screen, nil)
    |> assign(:coverage, nil)
    |> assign(:coverage_detail, nil)
    |> assign(:invalid_calendars, [])
    |> assign(:long_history?, false)
  end

  # The success summary names the retained sources the reviewer can still see. A source the current
  # search or status filter hides is stated as hidden instead of being presented as if it were on
  # screen, so the notice never describes a row the reviewer cannot find (AC-24). It is rewritten
  # only for the summary on screen, and the reload that follows a confirmation is what supplies it.
  defp note_hidden_combination_sources(
         %{assigns: %{combine_success: %{retained_ids: ids} = success}} = socket
       )
       when is_list(ids) do
    visible = MapSet.new(socket.assigns.calendars, & &1.service_id)

    hidden_names =
      ids
      |> Enum.reject(&MapSet.member?(visible, &1))
      |> Enum.map(fn service_id ->
        case Enum.find(socket.assigns.all_calendars, &(&1.service_id == service_id)) do
          nil -> service_id
          row -> row.name || row.service_id
        end
      end)

    assign(socket, :combine_success, %{success | hidden_names: hidden_names})
  end

  defp note_hidden_combination_sources(socket), do: socket

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
    |> prune_selection()
  end

  ## Selection

  # Selection is a set of exact service IDs, so a read that still returns the same
  # identities keeps it: sorting and the timeline range leave the matching rows alone and
  # the selection stays. A filter or a refresh changes which rows match, and the selection
  # is then the intersection with the rows the list can currently offer (AC-20). An
  # identity whose retained range cannot be read is never selectable (AC-5); its ID cannot
  # enter the set through a row, and a forged event is rejected here too.
  defp prune_selection(socket) do
    selectable = MapSet.new(selectable_calendars(socket), & &1.service_id)
    selected = MapSet.intersection(socket.assigns.selected_service_ids, selectable)

    if MapSet.equal?(selected, socket.assigns.selected_service_ids) do
      socket
    else
      socket
      |> assign(:selected_service_ids, selected)
      |> drop_combination()
    end
  end

  defp selectable_calendars(socket),
    do: Enum.filter(socket.assigns.calendars, &is_nil(&1.coverage_error))

  defp selected_calendar_rows(socket) do
    selected = socket.assigns.selected_service_ids

    socket.assigns.calendars
    |> Enum.filter(&MapSet.member?(selected, &1.service_id))
    |> Enum.reject(& &1.coverage_error)
  end

  defp toggle_calendar_selection(socket, service_id) do
    case Enum.find(selectable_calendars(socket), &(&1.service_id == service_id)) do
      nil ->
        socket

      row ->
        socket
        |> assign(
          :selected_service_ids,
          toggle(socket.assigns.selected_service_ids, service_id)
        )
        |> drop_combination()
        |> stream_insert(:calendars, row)
    end
  end

  # A streamed row is only re-sent by a stream operation, so a control that lives inside a
  # row states its new state by inserting the rows whose checkbox changed. The insert keeps
  # the row's DOM id, so LiveView patches the existing element instead of replacing it and
  # the checkbox keeps focus.
  defp restream_calendars(socket, rows),
    do: Enum.reduce(rows, socket, &stream_insert(&2, :calendars, &1))

  # The selection belongs to one version. The router navigates between versions on the same
  # LiveView, so the recorded version is what distinguishes a filter patch from a version
  # change, and only the latter clears every piece of review state (AC-20).
  defp clear_selection_for_version(socket) do
    version_id = socket.assigns.current_gtfs_version.id

    if socket.assigns.selection_version_id == version_id do
      socket
    else
      socket
      |> assign(:selected_service_ids, MapSet.new())
      |> assign(:selection_version_id, version_id)
      |> drop_combination()
      |> clear_combination_notices()
    end
  end

  ## Combination review

  # Opening the drawer reviews the selected calendars and writes nothing: the review command
  # reads one protected input set and returns the union, the conflicts, the per-calendar
  # effects and the block/transfer projection, all bound to a fingerprint the write path
  # would have to reproduce. Nothing here persists, and a version holding an unreadable
  # range cannot combine at all (AC-5).
  defp open_combine(socket) do
    rows = selected_calendar_rows(socket)

    if length(rows) < 2 or socket.assigns.invalid_calendars != [] do
      socket
    else
      review_combination(socket, rows, default_destination(rows))
    end
  end

  # The default destination is the selection's most-used calendar; a tie follows the list's
  # own case-insensitive display-name ordering and then the exact service ID, so the choice
  # never depends on click order (AC-20).
  defp default_destination(rows) do
    rows
    |> Enum.min_by(&{-&1.trip_count, Calendars.display_sort_key(&1), &1.service_id})
    |> Map.fetch!(:service_id)
  end

  defp change_combination(
         %{assigns: %{combine_pending?: true}} = socket,
         _destination_id,
         _decisions
       ),
       do: socket

  # One form event carries both the kept calendar and the answered conflicts. Changing the kept
  # calendar discards every answer, because the conflicts themselves are recomputed (AC-22); a new
  # answer re-reviews against the current conflicts and the domain's own group keys, so a forged or
  # outdated key is refused rather than expanded (INV-3).
  defp change_combination(socket, destination_id, decisions) do
    rows = socket.assigns.combine_rows
    unchanged? = destination_id == socket.assigns.combine_destination_id
    answered_same? = decisions == socket.assigns.combine_decisions

    cond do
      not Enum.any?(rows, &(&1.service_id == destination_id)) -> socket
      unchanged? and answered_same? -> socket
      unchanged? -> review_combination(socket, rows, destination_id, decisions)
      true -> review_combination(socket, rows, destination_id, %{})
    end
  end

  # Only the two domain decisions and the current review's own conflict groups can enter the
  # submitted map: an unknown value or a group this review does not carry is dropped here and
  # refused again by `Combination.expand_group_choices/2`.
  defp submitted_decisions(params) do
    case params["decisions"] do
      decisions when is_map(decisions) ->
        for {key, value} <- decisions,
            is_binary(key),
            is_binary(value),
            value in @combine_decision_values,
            into: %{},
            do: {key, value}

      _other ->
        %{}
    end
  end

  defp review_combination(socket, rows, destination_id, decisions \\ %{}) do
    sources =
      rows
      |> Enum.map(& &1.service_id)
      |> Enum.reject(&(&1 == destination_id))
      |> Enum.sort()

    fingerprints = Map.new(rows, &{&1.service_id, &1.fingerprint})

    case expand_combination_decisions(socket, destination_id, decisions) do
      {:ok, decision_dates} ->
        case Gtfs.review_calendar_change(
               {:combine, destination_id, sources, decision_dates},
               fingerprints,
               audit_context(socket)
             ) do
          {:ok, review} ->
            socket
            |> assign(:combine_open?, true)
            |> assign(:combine_error, nil)
            |> assign(:combine_destination_id, destination_id)
            |> assign(:combine_review, review)
            |> assign(:combine_rows, rows)
            |> assign(:combine_stored, stored_destination(review, rows, destination_id))
            |> assign(:combine_form, combine_form(destination_id))
            |> assign(:combine_decisions, decisions)
            |> assign(:combine_decision_dates, decision_dates)
            |> assign(:combine_refresh_required?, false)
            |> assign_combination_choice_status()
            |> assign(:combine_return_focus_id, "calendar-combine-open")
            |> bump_combine_generation()

          {:error, reason} ->
            socket
            |> drop_combination()
            |> assign(:combine_error, combine_error_message(reason))
        end

      :error ->
        socket
    end
  end

  # The drawer decides group keys, the domain expands them into the exact ISO-8601 dates of the
  # review it is looking at, and `apply_calendar_change/3` receives only that expansion. An answer
  # for a group that is no longer current is refused instead of being guessed at.
  defp expand_combination_decisions(_socket, _destination_id, decisions)
       when map_size(decisions) == 0,
       do: {:ok, %{}}

  defp expand_combination_decisions(socket, destination_id, decisions) do
    review = socket.assigns.combine_review

    if is_map(review) and socket.assigns.combine_destination_id == destination_id do
      Combination.expand_group_choices(review.conflicts, decisions)
    else
      :error
    end
  end

  # The review's own result dates reach the destination's native rows through the same public
  # projection the write path validates with, so the drawer can state exactly what would be
  # stored without restating any encoding rule here.
  defp stored_destination(
         %{ready?: true, plan: %{result_dates: result_dates}} = review,
         rows,
         id
       )
       when is_list(result_dates) do
    destination = Enum.find(rows, &(&1.service_id == id))

    snapshot = %{
      calendar: destination.calendar,
      exceptions: destination.exceptions,
      trip_count: destination.trip_count
    }

    post_move_trip_count = destination.trip_count + review.moved_trip_count

    case Combination.encode(snapshot, result_dates, post_move_trip_count) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> nil
    end
  end

  defp stored_destination(_review, _rows, _destination_id), do: nil

  # A closed drawer keeps only the list. The return-focus target survives the close patch so the
  # dialog hook can hand focus back to the control that opened it, exactly as the date-change
  # drawer does; it is replaced on the next review and cleared only by a version change. Dropping
  # the review also supersedes it: every path that clears it bumps the generation here, so a result
  # still in flight settles against nothing instead of being presented (or read) after the review
  # it belonged to is gone.
  defp drop_combination(socket) do
    socket
    |> assign(:combine_open?, false)
    |> assign(:combine_error, nil)
    |> assign(:combine_destination_id, nil)
    |> assign(:combine_review, nil)
    |> assign(:combine_rows, [])
    |> assign(:combine_stored, nil)
    |> assign(:combine_form, combine_form(nil))
    |> assign(:combine_decisions, %{})
    |> assign(:combine_decision_dates, %{})
    |> assign(:combine_attempted?, false)
    |> assign(:combine_pending?, false)
    |> assign(:combine_refresh_required?, false)
    |> assign(:combine_status, nil)
    |> assign(:combine_dispatched?, false)
    |> bump_combine_generation()
  end

  defp clear_combination_notices(socket) do
    socket
    |> assign(:combine_success, nil)
    |> assign(:combine_highlight, MapSet.new())
    |> assign(:combine_return_focus_id, nil)
  end

  # Every review owns a generation. A confirmation dispatched by an older generation is never
  # presented as the outcome of the review on screen: a version change, a new review or a reselection
  # supersedes it. Nothing here cancels or rolls back the transaction the task already ran.
  defp bump_combine_generation(socket),
    do: assign(socket, :combine_generation, socket.assigns.combine_generation + 1)

  ## Combination submission and recovery

  # The one confirmation path. Only a complete current review carries an applicable token, so a
  # review whose conflicts are unanswered never reaches `apply_calendar_change/3` and never invents
  # a fingerprint: it states the missing choices, marks the groups it still needs and moves focus to
  # the first unresolved option (AC-22). A complete review renders pending, keeps the review and its
  # audit context in the task's closure, and settles once on the async result.
  defp apply_combination(socket) do
    case socket.assigns.combine_review do
      %{ready?: true, fingerprint: fingerprint} when is_binary(fingerprint) ->
        dispatch_combination(socket, fingerprint)

      %{conflicts: _conflicts} ->
        require_combination_choices(socket)

      _incomplete ->
        socket
    end
  end

  # The groups that are still unanswered and their labels have one owner: the component that marks
  # them uses the same `CalendarComponents.unanswered_conflict_labels/2` the announcement does, so a
  # summary can never name a group the drawer does not mark (AC-22).
  defp require_combination_choices(socket) do
    socket
    |> assign(:combine_attempted?, true)
    |> assign_combination_choice_status()
    |> focus_combination_error()
  end

  # The announced refusal follows the current review: after a refused submit it names the groups the
  # review is still missing an answer for, it shrinks as the reviewer answers them, and a complete
  # review clears it (AC-22).
  defp assign_combination_choice_status(%{assigns: %{combine_attempted?: true}} = socket) do
    case missing_choice_labels(socket) do
      [] ->
        assign(socket, :combine_status, nil)

      labels ->
        assign(socket, :combine_status, %{
          kind: :missing,
          title: "Calendars not combined yet.",
          message: "Choose what happens on #{labels_and(labels)}."
        })
    end
  end

  defp assign_combination_choice_status(socket), do: assign(socket, :combine_status, nil)

  defp missing_choice_labels(%{assigns: %{combine_review: %{conflicts: conflicts}} = assigns}) do
    conflicts
    |> CalendarComponents.unanswered_conflict_labels(assigns.combine_decisions)
    |> Enum.map(& &1.label)
  end

  defp missing_choice_labels(_socket), do: []

  defp labels_and([]), do: ""
  defp labels_and([label]), do: label

  defp labels_and(labels),
    do: Enum.join(Enum.drop(labels, -1), ", ") <> " and " <> List.last(labels)

  # Every drawer state that has something to resolve hands focus back through the page's existing
  # scoped focus hook: it lands on the form's first invalid control when the refusal is a missing
  # choice, and on the announced status otherwise (AC-22, AC-23).
  defp focus_combination_error(socket) do
    push_event(socket, "focus_form_error", %{
      form_id: "calendar-combine-form",
      fallback_id: "calendar-combine-errors"
    })
  end

  # The reviewed command is built from the review on screen and nothing else, and the audit/scope
  # travel with it in the task's closure, so the async task needs no access to the socket. Pending is
  # assigned before the task starts, which is what makes the drawer render its in-flight state before
  # any write begins.
  defp dispatch_combination(socket, fingerprint) do
    command =
      {:combine, socket.assigns.combine_destination_id,
       socket.assigns.combine_review.retained_sources, socket.assigns.combine_decision_dates}

    audit = audit_context(socket)
    generation = socket.assigns.combine_generation

    socket
    |> assign(:combine_attempted?, false)
    |> assign(:combine_status, %{
      kind: :pending,
      title: nil,
      message: pending_combination_note(socket.assigns)
    })
    |> assign(:combine_pending?, true)
    |> assign(:combine_dispatched?, true)
    |> start_async({:combine_apply, generation}, fn ->
      {:applied, Gtfs.apply_calendar_change(command, fingerprint, audit)}
    end)
  end

  # Both the socket and the render assigns carry these keys, so the pending note reads the review
  # it was dispatched from without depending on a socket.
  defp pending_combination_note(assigns) do
    case Enum.find(
           assigns.combine_rows,
           &(&1.service_id == assigns.combine_destination_id)
         ) do
      nil ->
        "Combining the reviewed calendars…"

      row ->
        count = assigns.combine_review.moved_trip_count

        "Moving #{count} #{if count == 1, do: "trip", else: "trips"} into #{row.name || row.service_id}…"
    end
  end

  # The async task reports the domain's own return value, which is itself a tuple, so the result is
  # wrapped once: every clause below then reads exactly one shape, and an unexpected one is reported
  # as an unconfirmed outcome rather than as a success.
  defp settle_combination(socket, {:ok, {:applied, {:ok, %{action: :unchanged}}}}),
    do: combination_unchanged(socket)

  defp settle_combination(socket, {:ok, {:applied, {:ok, result}}}),
    do: combination_combined(socket, result)

  defp settle_combination(socket, {:ok, {:applied, {:error, :stale_review}}}),
    do: combination_stale(socket)

  defp settle_combination(socket, {:ok, {:applied, {:error, :invalid_command}}}),
    do: combination_outdated(socket)

  defp settle_combination(socket, {:ok, {:applied, {:error, reason}}}),
    do: combination_failed(socket, reason)

  defp settle_combination(socket, {:exit, _reason}), do: combination_unconfirmed(socket)
  defp settle_combination(socket, _unexpected), do: combination_unconfirmed(socket)

  defp combination_combined(socket, result) do
    review = socket.assigns.combine_review
    rows = socket.assigns.combine_rows
    retained = Enum.filter(rows, &(&1.service_id in (review.retained_sources || [])))

    socket
    |> assign(
      :combine_success,
      combination_success(result, socket.assigns.combine_destination_id, rows, retained, review)
    )
    |> assign(
      :combine_highlight,
      MapSet.new([socket.assigns.combine_destination_id | Enum.map(retained, & &1.service_id)])
    )
    |> drop_combination()
    |> assign(:selected_service_ids, MapSet.new())
    |> success_focus()
    |> reload_calendars()
  end

  defp combination_success(result, destination_id, rows, retained, review) do
    destination = Enum.find(rows, &(&1.service_id == destination_id))

    %{
      action: :combined,
      destination_id: destination_id,
      destination_name:
        (destination && (destination.name || destination.service_id)) || destination_id,
      moved_trip_count: result.moved_trip_count,
      retained_count: length(retained),
      retained_names: Enum.map_join(retained, " and ", &(&1.name || &1.service_id)),
      retained_ids: Enum.map(retained, & &1.service_id),
      cleared_trip_count: cleared_trip_count(review),
      hidden_names: []
    }
  end

  # A row the confirmed combination touched keeps its tint while the summary is on screen, and the
  # opening control is gone once the selection is cleared, so the summary itself is where focus
  # returns (AC-24).
  defp success_focus(socket) do
    socket
    |> assign(:combine_return_focus_id, "calendar-combine-success")
    |> push_event("calendar:combine-focus", %{id: "calendar-combine-success"})
  end

  defp cleared_trip_count(%{block_effects: %{cleared_trip_ids: ids}}) when is_list(ids),
    do: length(ids)

  defp cleared_trip_count(_review), do: 0

  # The destination's own dates already matched and no source had a trip: the same public command
  # reports `:unchanged` with no operation UUID, so the page states that nothing changed instead of
  # claiming a move.
  defp combination_unchanged(socket) do
    destination = socket.assigns.combine_destination_id
    row = Enum.find(socket.assigns.combine_rows, &(&1.service_id == destination))

    socket
    |> assign(:combine_success, %{
      action: :unchanged,
      destination_id: destination,
      destination_name: (row && (row.name || row.service_id)) || destination,
      moved_trip_count: 0,
      retained_count: length(socket.assigns.combine_review.retained_sources || []),
      retained_names: "",
      retained_ids: [],
      cleared_trip_count: 0,
      hidden_names: []
    })
    |> drop_combination()
    |> success_focus()
    |> reload_calendars()
  end

  # A stale review writes nothing and cannot be reapplied: the reviewer's inputs and answers stay,
  # the token is dropped, and the only action left is an explicit refresh (AC-23).
  defp combination_stale(socket) do
    socket
    |> assign(:combine_pending?, false)
    |> assign(:combine_dispatched?, false)
    |> assign(:combine_refresh_required?, true)
    |> assign(:combine_status, %{
      kind: :stale,
      title: "#{destination_label(socket)} changed after this review was prepared.",
      message:
        "Another editor changed these calendars, so nothing was combined. Refresh the review to see " <>
          "the current result, then combine again."
    })
    |> focus_combination_error()
  end

  # The reviewed rows moved on, but the choice the reviewer gave no longer describes them: the
  # domain refuses the command instead of a mismatch, because the current calendars no longer carry
  # the conflict the choice names. Nothing was written, and the recovery is the same explicit
  # refresh - a stale review is never resubmitted as if it were current (AC-23).
  defp combination_outdated(socket) do
    socket
    |> assign(:combine_pending?, false)
    |> assign(:combine_dispatched?, false)
    |> assign(:combine_refresh_required?, true)
    |> assign(:combine_status, %{
      kind: :stale,
      title: "#{destination_label(socket)} changed after this review was prepared.",
      message:
        "Nothing was combined. Your choice no longer matches the current calendars, so refresh the " <>
          "review to see the current result and combine again."
    })
    |> focus_combination_error()
  end

  # An ordinary failure keeps every input and answer, so the reviewer can confirm again with the
  # same review. The message is the domain's own refusal, never a rewritten one.
  defp combination_failed(socket, reason) do
    socket
    |> assign(:combine_pending?, false)
    |> assign(:combine_dispatched?, false)
    |> assign(:combine_status, %{
      kind: :failed,
      title: "Calendars weren’t combined.",
      message:
        "#{combination_failure_message(reason)} Your choices are kept, so you can try again."
    })
    |> focus_combination_error()
  end

  defp combination_failure_message({:invalid_calendar, service_id, _reason}),
    do: combine_error_message({:invalid_calendar, service_id, nil})

  defp combination_failure_message(reason), do: combine_error_message(reason)

  # No answer arrived for a confirmation that was already dispatched, so the outcome is unknown
  # rather than rolled back: the page reloads the authoritative list and requires a fresh review
  # instead of resending the old command.
  defp combination_unconfirmed(socket) do
    socket
    |> assign(:combine_pending?, false)
    |> assign(:combine_dispatched?, false)
    |> assign(:combine_refresh_required?, true)
    |> assign(:combine_status, %{
      kind: :unconfirmed,
      title: "Your confirmation has no answer yet.",
      message:
        "It may still have been applied, so this page will not claim it was rolled back. " <>
          "Refresh the review after the list reloads, then combine again."
    })
    |> focus_combination_error()
    |> reload_calendars()
  end

  defp destination_label(socket) do
    case Enum.find(
           socket.assigns.combine_rows,
           &(&1.service_id == socket.assigns.combine_destination_id)
         ) do
      nil -> "A selected calendar"
      row -> row.name || row.service_id
    end
  end

  # The transport hook reports a reconnect. The socket cannot observe a disconnect, so a
  # confirmation that was dispatched before the connection dropped is reported as unconfirmed and
  # the authoritative list is re-read; the reviewer then gets a fresh review. Without a dispatched
  # confirmation the reconnect only reloads the list.
  defp reconnect_combination(socket) do
    if socket.assigns.combine_dispatched? do
      socket
      |> assign(:combine_refresh_required?, true)
      |> assign(:combine_status, %{
        kind: :unconfirmed,
        title: "Connection restored.",
        message:
          "Your confirmation was still unanswered when the connection dropped, so its outcome is " <>
            "unconfirmed: it may have been applied. The list has been reloaded from the server; " <>
            "refresh the review before confirming again."
      })
      |> reload_calendars()
    else
      reload_calendars(socket)
    end
  end

  # Refresh review re-reads the authoritative inputs, keeps the reviewer's own selection where it
  # still exists, recomputes the destination when the kept one is gone, and discards every answer: a
  # refreshed review is a new review, so the old confirmation can never be reused (AC-23).
  defp refresh_combination(socket) do
    socket
    |> load_calendars()
    |> refresh_open_combination()
  end

  defp refresh_open_combination(socket) do
    if socket.assigns.combine_open? do
      rebuild_open_combination(socket)
    else
      socket
    end
  end

  defp rebuild_open_combination(socket) do
    rows = selected_calendar_rows(socket)
    kept = socket.assigns.combine_destination_id

    cond do
      length(rows) < 2 ->
        socket
        |> drop_combination()
        |> assign(:combine_error, "The selection no longer holds two calendars to combine.")

      socket.assigns.invalid_calendars != [] ->
        socket
        |> drop_combination()
        |> assign(:combine_error, combine_error_message(:unavailable))

      true ->
        refreshed =
          socket
          |> assign(:combine_attempted?, false)
          |> review_combination(rows, kept_combination_destination(rows, kept), %{})

        assign(
          refreshed,
          :combine_status,
          refreshed_combination_status(refreshed.assigns.combine_review)
        )
    end
  end

  # A refresh keeps the reviewer's own destination while it is still part of the selection, and
  # recomputes the default one when it is gone: a refreshed review always has a valid destination.
  defp kept_combination_destination(rows, kept) do
    if Enum.any?(rows, &(&1.service_id == kept)) do
      kept
    else
      default_destination(rows)
    end
  end

  # A refreshed review is a new review: it states that it was rebuilt, that every answer was
  # cleared, and how many current dates still need one, so the reviewer is never left believing an
  # old confirmation still applies (AC-23).
  defp refreshed_combination_status(%{conflicts: []}) do
    %{
      kind: :refreshed,
      title: "Review refreshed.",
      message: "The review was rebuilt from the current calendars and every answer was cleared."
    }
  end

  defp refreshed_combination_status(%{conflicts: [_conflict | _rest] = conflicts}) do
    dates = length(conflicts)
    verb = if dates == 1, do: "needs", else: "need"

    %{
      kind: :refreshed,
      title: "Review refreshed.",
      message:
        "#{dates} #{if dates == 1, do: "date", else: "dates"} now #{verb} a choice. The review " <>
          "was rebuilt from the current calendars and every answer was cleared."
    }
  end

  defp refreshed_combination_status(_closed) do
    %{
      kind: :refreshed,
      title: "Review refreshed.",
      message: "The review was rebuilt from the current calendars and every answer was cleared."
    }
  end

  defp combine_form(destination_id),
    do: to_form(%{"destination_id" => destination_id}, as: :combine)

  defp combine_error_message({:invalid_calendar, service_id, _reason}) do
    "#{service_id} could not be read, so these calendars cannot be combined. Repair it and reload the list."
  end

  defp combine_error_message(:native_service_required) do
    "The kept calendar has no weekly days or stored dates to carry the result. Choose another calendar to keep."
  end

  defp combine_error_message(:stale_review) do
    "This list changed in another session. Refresh it and select the calendars again."
  end

  defp combine_error_message(:invalid_command) do
    "These calendars changed, so this review no longer describes them. Refresh the review to see the current result."
  end

  defp combine_error_message(:busy) do
    "Another editor is changing these calendars. Try again in a moment."
  end

  defp combine_error_message(:forbidden), do: write_error_message(:forbidden)
  defp combine_error_message(:not_found), do: write_error_message(:not_found)

  defp combine_error_message(_reason),
    do: "The calendars could not be combined. Nothing was written; try again."

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

  ## Date-change state

  # One snapshot per opened drawer: the loaded rows and their fingerprints stay
  # exactly as the list read them until the reviewer discards, refreshes or
  # applies, so a newer commit in another session is detected instead of silently
  # overwritten (INV-4, CR-7).
  defp open_date_change(socket, date_value) do
    socket
    |> assign(:date_change_open?, true)
    |> assign(:date_change_origin, nil)
    |> assign(:date_change_sources, snapshot_sources(socket.assigns.all_calendars))
    |> assign(:date_change_mode, "single")
    |> assign(:date_change_manual?, false)
    |> assign(:date_change_remove, MapSet.new())
    |> assign(:date_change_add, MapSet.new())
    |> assign(:date_change_errors, %{})
    |> assign(:date_change_review, nil)
    |> assign(:date_change_pending?, false)
    |> assign(:date_change_status, nil)
    |> assign_date_change_form("single", %{"date" => date_value || ""})
    |> assign(:date_change_return_focus, date_change_return_focus(date_value))
    |> put_date_change_dates(opened_dates(date_value))
  end

  defp opened_dates(date_value) do
    case parse_date(date_value) do
      {:ok, date} -> [date]
      :error -> []
    end
  end

  defp date_change_return_focus(date_value) do
    if is_binary(date_value) and String.trim(date_value) != "" do
      "calendars-feed-gap-review"
    else
      "calendar-date-change"
    end
  end

  # Closing keeps only the list: the drawer drops its snapshot, so a reopened
  # drawer always starts from the rows the list currently shows.
  defp close_date_change(socket) do
    socket
    |> restore_agent_return_focus()
    |> assign(:date_change_open?, false)
    |> assign(:date_change_sources, %{})
    |> assign(:date_change_dates, [])
    |> assign(:date_change_remove, MapSet.new())
    |> assign(:date_change_add, MapSet.new())
    |> assign(:date_change_errors, %{})
    |> assign(:date_change_review, nil)
    |> assign(:date_change_pending?, false)
    |> assign(:date_change_mode, "single")
    |> assign(:date_change_origin, nil)
    |> assign_date_change_form("single", %{})
  end

  ## Approved extension state

  defp open_extension_approval(socket) do
    socket
    |> assign(:extension_form, extension_form(%{}))
    |> assign(:extension_errors, %{})
    |> assign(:extension_notice, nil)
    |> assign(:extension_success, nil)
    |> assign(:extension_open?, false)
    |> assign(:extension_review, nil)
    |> assign(:extension_origin, nil)
    |> assign(:extension_pending?, false)
    |> assign(:extension_dispatched?, false)
    |> assign(:extension_generation, 0)
    |> assign(:extension_status, nil)
    |> assign(:extension_return_focus, "calendar-extension-approve")
    |> assign(:extension_refresh_required?, false)
    |> assign(:extension_review_form, extension_review_form(%{}))
  end

  defp extension_form(values) do
    defaults = %{"service_id" => "", "end_date" => "", "approval_text" => ""}

    to_form(Map.merge(defaults, values), as: :extension)
  end

  defp extension_review_form(values) do
    to_form(Map.merge(%{"end_date" => ""}, values), as: :extension_review)
  end

  # A form event arrives nested under the form name; a bare input event arrives flat.
  defp extension_params(params) do
    case params["extension"] do
      nested when is_map(nested) -> Map.merge(params, nested)
      _other -> params
    end
  end

  defp extension_review_params(params) do
    case params["extension_review"] do
      nested when is_map(nested) -> Map.merge(params, nested)
      _other -> params
    end
  end

  defp approve_extension(socket, params) do
    values = %{
      "service_id" => String.trim(to_string(params["service_id"] || "")),
      "end_date" => String.trim(to_string(params["end_date"] || "")),
      "approval_text" => String.trim(to_string(params["approval_text"] || ""))
    }

    case extension_approval_errors(socket, values) do
      {:ok, approved} ->
        context = %{
          identity: {:version, socket.assigns.current_gtfs_version.id},
          approved_extension: approved
        }

        socket
        |> assign(:extension_form, extension_form(values))
        |> assign(:extension_errors, %{})
        |> assign(:extension_notice, extension_approved_message(approved))
        |> assign(:extension_success, nil)
        |> AgentPanel.set_context(context)

      {:error, errors} ->
        socket
        |> assign(:extension_form, extension_form(values))
        |> assign(:extension_errors, errors)
        |> assign(:extension_notice, nil)
        |> focus_extension_approval()
    end
  end

  # Every rule here is the editor's own: the calendar must be a weekly calendar
  # this version lists, the end date must be a real later date within the fixed
  # 366-day horizon, and the approval must be the editor's own words. The domain
  # refuses the same conditions again when it reviews the command, so this
  # validation only keeps an unusable approval out of the session context.
  defp extension_approval_errors(socket, values) do
    case Enum.find(socket.assigns.all_calendars, &(&1.service_id == values["service_id"])) do
      nil ->
        {:error, %{service_id: "Choose a calendar from this list."}}

      summary ->
        approved_end_date_errors(summary, values)
    end
  end

  defp approved_end_date_errors(%{kind: kind, calendar: calendar}, values)
       when kind != :weekly or is_nil(calendar) do
    _ = values
    {:error, %{service_id: "Only a weekly calendar can be extended. Use a service date instead."}}
  end

  defp approved_end_date_errors(summary, values) do
    case parse_date(values["end_date"]) do
      {:ok, end_date} -> approved_extension_errors(summary, values, end_date)
      :error -> {:error, %{end_date: "Choose the new last date of service."}}
    end
  end

  defp approved_extension_errors(summary, values, end_date) do
    cond do
      values["approval_text"] == "" ->
        {:error, %{approval_text: "Enter why you are approving this extension."}}

      overlong_approval?(values["approval_text"]) ->
        {:error, %{approval_text: "Keep the approval under #{@max_approval_length} characters."}}

      not later_end_date?(summary, end_date) ->
        {:error,
         %{
           end_date:
             "That date is not later than the calendar's current end date, #{CalendarComponents.format_date(summary.calendar.end_date)}."
         }}

      over_extension_horizon?(summary, end_date) ->
        {:error,
         %{
           end_date:
             "An extension can add at most #{@max_extension_days} days. Ask the editor to approve a shorter period."
         }}

      true ->
        {:ok,
         %{
           service_id: values["service_id"],
           end_date: end_date,
           approval_text: values["approval_text"]
         }}
    end
  end

  defp overlong_approval?(text), do: String.length(text) > @max_approval_length

  defp later_end_date?(summary, %Date{} = end_date) do
    Date.compare(end_date, summary.calendar.end_date) == :gt
  end

  defp over_extension_horizon?(summary, %Date{} = end_date) do
    Date.diff(end_date, summary.calendar.end_date) > @max_extension_days
  end

  defp extension_approved_message(approved) do
    "Approved extending #{approved.service_id} through #{CalendarComponents.format_date(approved.end_date)}. " <>
      "Ask the helper to prepare it, then review the result before it is applied."
  end

  defp focus_extension_approval(socket) do
    push_event(socket, "focus_form_error", %{
      form_id: "calendar-extension-form",
      fallback_id: "calendar-extension-errors"
    })
  end

  # The review is regenerated from the page's own snapshot and the exact prepared
  # command, so what the reviewer reads is what Apply will compare (AC-14). The
  # session's proposal stays untouched: it is released only by an exact apply.
  defp open_extension_review(socket, entry_id, service_id, attrs) do
    sources = snapshot_sources(socket.assigns.all_calendars)

    case Map.fetch(sources, service_id) do
      {:ok, source} ->
        review_extension_command(socket, entry_id, service_id, attrs, source.fingerprint)

      :error ->
        assign(socket, :agent_notice, @prepared_missing_notice)
    end
  end

  defp review_extension_command(socket, entry_id, service_id, attrs, fingerprint) do
    command = {:save, service_id, attrs}

    case Gtfs.review_calendar_change(
           command,
           %{service_id => fingerprint},
           audit_context(socket)
         ) do
      {:ok, %{extension: extension} = review} when not is_nil(extension) ->
        socket
        |> assign(:extension_open?, true)
        |> assign(:extension_status, nil)
        |> assign(:extension_refresh_required?, false)
        |> assign(:extension_review, %{
          command: command,
          fingerprint: review.fingerprint,
          extension: extension,
          approval_text: attrs[:approval_text],
          warnings: review.warnings
        })
        |> assign(
          :extension_review_form,
          extension_review_form(%{"end_date" => Date.to_iso8601(extension.requested_end_date)})
        )
        |> assign(:extension_origin, %{
          session_pid: socket.assigns.agent_session,
          conversation_id: socket.assigns.agent_conversation_id,
          entry_id: entry_id,
          command: command
        })
        |> assign(:extension_return_focus, "agent-prepared-#{entry_id}")
        |> bump_extension_generation()

      {:ok, _review} ->
        assign(socket, :agent_notice, @extension_missing_notice)

      {:error, reason} ->
        assign(socket, :agent_notice, extension_review_error_message(reason))
    end
  end

  # Re-runs the same review against the current snapshot. A second review never
  # replaces an open reviewer's own command, and a stale one cannot be reapplied.
  defp review_extension(socket) do
    case socket.assigns.extension_review do
      %{command: {:save, service_id, attrs}} ->
        fingerprint =
          socket.assigns.all_calendars
          |> Enum.find(&(&1.service_id == service_id))
          |> case do
            nil -> nil
            summary -> summary.fingerprint
          end

        if is_nil(fingerprint) do
          assign(socket, :agent_notice, @prepared_missing_notice)
        else
          review_extension_command(
            socket,
            socket.assigns.extension_origin.entry_id,
            service_id,
            attrs,
            fingerprint
          )
        end

      nil ->
        socket
    end
  end

  # An edited end date is an edited native value. The approval travels with it,
  # because the editor approved this calendar's extension and a reviewer's own
  # change to the date is still reviewed, dated and bounded the same way.
  defp change_extension_end_date(socket, params) do
    case socket.assigns.extension_review do
      %{command: {:save, service_id, %{approval_text: approval_text}}} ->
        value = String.trim(to_string(params["end_date"] || ""))

        case parse_date(value) do
          {:ok, date} ->
            socket
            |> assign(:extension_review_form, extension_review_form(%{"end_date" => value}))
            |> review_extension_command(
              socket.assigns.extension_origin.entry_id,
              service_id,
              %{end_date: date, approval_text: approval_text},
              extension_fingerprint(socket, service_id)
            )

          :error ->
            socket
            |> assign(:extension_review_form, extension_review_form(%{"end_date" => value}))
            |> assign(:extension_status, %{
              kind: :failed,
              title: "That end date could not be read.",
              message: "Choose a date like 2027-06-30 to review this extension."
            })
            |> focus_extension_review()
        end

      _other ->
        socket
    end
  end

  defp extension_fingerprint(socket, service_id) do
    case Enum.find(socket.assigns.all_calendars, &(&1.service_id == service_id)) do
      nil -> nil
      summary -> summary.fingerprint
    end
  end

  defp extension_option(summary), do: summary.name || summary.service_id

  # Only a weekly calendar has an end date to extend, so the approval offers only
  # those: choosing one that cannot be extended is refused before it is stored.
  defp extension_options(assigns) do
    Enum.filter(assigns.all_calendars, &(&1.kind == :weekly and not is_nil(&1.calendar)))
  end

  defp extension_status_kind(%{extension_status: %{kind: :success}}), do: "success"
  defp extension_status_kind(%{extension_status: %{kind: :failed}}), do: "error"
  defp extension_status_kind(_assigns), do: "warning"

  defp extension_review_error_message(:stale_review),
    do:
      "These calendars changed in another session. Refresh the list and prepare the extension again."

  defp extension_review_error_message(:extension_requires_weekly_calendar),
    do: "Only a weekly calendar can be extended this way."

  defp extension_review_error_message(:extension_requires_later_end_date),
    do: "That end date is not later than the calendar's current end date."

  defp extension_review_error_message(:extension_exceeds_max_days),
    do: "An extension can add at most #{@max_extension_days} days."

  defp extension_review_error_message(reason), do: extension_write_error_message(reason)

  defp extension_write_error_message(reason), do: write_error_message(reason)

  # The reviewed command and its audit context travel into the task, and the
  # pending state is assigned before the task starts, so the reviewer sees the
  # in-flight state before any write begins.
  defp dispatch_extension(socket) do
    case socket.assigns.extension_review do
      %{command: command, fingerprint: fingerprint} ->
        audit = audit_context(socket)
        # Every dispatch owns a generation, and the socket carries it: a result
        # from a superseded review is never presented as the outcome of the one
        # on screen.
        generation = socket.assigns.extension_generation + 1

        socket
        |> assign(:extension_generation, generation)
        |> assign(:extension_pending?, true)
        |> assign(:extension_dispatched?, true)
        |> start_async({:extension_apply, generation}, fn ->
          {:applied, Gtfs.apply_calendar_change(command, fingerprint, audit)}
        end)

      nil ->
        socket
    end
  end

  defp bump_extension_generation(socket) do
    assign(socket, :extension_generation, socket.assigns.extension_generation + 1)
  end

  # The async task reports the domain's own return value, which is itself a tuple,
  # so the result is wrapped once and an unexpected shape is reported as an
  # unconfirmed outcome rather than as a success.
  defp settle_extension(socket, {:ok, {:applied, {:ok, %{action: :unchanged}}}}),
    do: extension_unchanged(socket)

  defp settle_extension(socket, {:ok, {:applied, {:ok, result}}}),
    do: extension_applied(socket, result)

  defp settle_extension(socket, {:ok, {:applied, {:error, :stale_review}}}),
    do: extension_stale(socket)

  defp settle_extension(socket, {:ok, {:applied, {:error, reason}}}),
    do: extension_failed(socket, reason)

  defp settle_extension(socket, {:exit, _reason}), do: extension_unconfirmed(socket)
  defp settle_extension(socket, _unexpected), do: extension_unconfirmed(socket)

  # One receipt per applied handoff: the exact reviewed command is compared with
  # the proposal inside the originating conversation. An edited command leaves the
  # card unconfirmed and says so, and a changed native value is never credited as
  # the helper's change (AC-16).
  defp extension_applied(socket, result) do
    socket
    |> assign(:extension_pending?, false)
    |> assign(:extension_success, extension_result_message(result, socket))
    |> record_prepared_applied(socket.assigns.extension_review.command)
    |> close_extension()
    |> push_event("focus_scoped_target", %{id: "calendar-extension-approve"})
    |> reload_calendars()
  end

  defp extension_unchanged(socket) do
    socket
    |> assign(:extension_pending?, false)
    |> assign(
      :extension_success,
      extension_service_label(socket) <> " already runs through the date you reviewed."
    )
    |> record_prepared_applied(socket.assigns.extension_review.command)
    |> close_extension()
    |> push_event("focus_scoped_target", %{id: "calendar-extension-approve"})
    |> reload_calendars()
  end

  # The outcome is the page's own message beside the list, because the review
  # drawer is closed by an apply: the reviewer still reads what was written and
  # which date the calendar now ends on.
  defp extension_result_message(result, socket) do
    changed = Map.get(result, :changed_count, 0)

    "Extended #{extension_service_label(socket)} through " <>
      "#{CalendarComponents.format_date(socket.assigns.extension_review.extension.requested_end_date)}. " <>
      "#{changed} #{if changed == 1, do: "row", else: "rows"} changed."
  end

  # A stale extension writes nothing and cannot be reapplied. The approval the
  # editor entered stays, the reviewed token is dropped, and the only action left
  # is an explicit refresh of the current end date (AC-15).
  defp extension_stale(socket) do
    socket
    |> assign(:extension_pending?, false)
    |> assign(:extension_dispatched?, false)
    |> assign(:extension_refresh_required?, true)
    |> assign(:extension_status, %{
      kind: :stale,
      title: "Nothing was extended.",
      message:
        "This calendar changed after the review was prepared, so nothing was written. Refresh the " <>
          "list, review the current end date and extend again."
    })
    |> focus_extension_review()
  end

  defp extension_failed(socket, reason) do
    socket
    |> assign(:extension_pending?, false)
    |> assign(:extension_status, %{
      kind: :failed,
      title: "Nothing was extended.",
      message:
        "#{extension_write_error_message(reason)} The review is still here, so you can try again."
    })
    |> focus_extension_review()
  end

  # A lost answer is not a rolled-back write: the page says the outcome is
  # unconfirmed, re-reads the authoritative list and never resends the command
  # on its own (AC-15, AC-16).
  defp extension_unconfirmed(socket) do
    socket
    |> assign(:extension_pending?, false)
    |> assign(:extension_dispatched?, false)
    |> assign(:extension_refresh_required?, true)
    |> assign(:extension_status, %{
      kind: :unconfirmed,
      title: "This extension has no answer yet.",
      message:
        "It may still have been applied, so nothing is claimed either way. Refresh the review " <>
          "after the list reloads, then decide again."
    })
    |> focus_extension_review()
    |> reload_calendars()
  end

  defp reconnect_extension(socket) do
    if socket.assigns.extension_dispatched? do
      extension_unconfirmed(socket)
    else
      socket
    end
  end

  defp extension_service_label(socket) do
    socket.assigns.extension_review.extension.service_id
  end

  defp focus_extension_review(socket) do
    push_event(socket, "calendar:combine-focus", %{
      id: "calendar-extension-apply",
      fallback_id: "calendar-extension-review"
    })
  end

  defp close_extension(socket) do
    socket
    |> restore_agent_return_focus()
    |> assign(:extension_open?, false)
    |> assign(:extension_review, nil)
    |> assign(:extension_origin, nil)
    |> assign(:extension_pending?, false)
    |> assign(:extension_dispatched?, false)
    |> assign(:extension_status, nil)
    |> assign(:extension_refresh_required?, false)
    |> assign(:extension_review_form, extension_review_form(%{}))
    |> bump_extension_generation()
  end

  ## Prepared-change handoff

  # A second handoff never replaces an open drawer's input (AC-28), and a forged
  # or malformed entry id is ignored instead of reaching the session.
  defp review_prepared_change(socket, id) do
    cond do
      socket.assigns.date_change_open? or socket.assigns.combine_open? or
          socket.assigns.extension_open? ->
        socket

      not is_binary(id) ->
        socket

      true ->
        case Integer.parse(id) do
          {entry_id, ""} -> handoff_prepared_change(socket, entry_id)
          _other -> socket
        end
    end
  end

  defp handoff_prepared_change(socket, entry_id) do
    case Agents.prepared(
           socket.assigns.agent_session,
           socket.assigns.agent_conversation_id,
           entry_id
         ) do
      {:ok, %{command: {:date_change, dates, remove_from, add_to}}} ->
        open_prepared_change(socket, entry_id, dates, remove_from, add_to)

      {:ok, %{command: {:save, service_id, attrs}}} ->
        open_extension_review(socket, entry_id, service_id, attrs)

      _stale_or_unknown ->
        assign(socket, :agent_notice, @prepared_missing_notice)
    end
  end

  # The snapshot membership check runs before `review_date_change/1`, because the
  # drawer reviews against the loaded list's snapshot and `target_fingerprints/2`
  # would raise on an unknown ID (FH-5). The pack's own catalog read can be fresher
  # than this page, so a missing ID is a notice and no drawer, never a crash.
  defp open_prepared_change(socket, entry_id, dates, remove_from, add_to) do
    sources = snapshot_sources(socket.assigns.all_calendars)

    if Enum.all?(Enum.uniq(remove_from ++ add_to), &Map.has_key?(sources, &1)) do
      command = {:date_change, dates, remove_from, add_to}

      socket
      |> open_date_change(nil)
      |> assign_date_change_form("several", %{})
      |> assign(:date_change_mode, "several")
      |> assign(:date_change_manual?, true)
      |> assign(:date_change_remove, MapSet.new(remove_from))
      |> assign(:date_change_add, MapSet.new(add_to))
      |> assign(:date_change_origin, %{
        session_pid: socket.assigns.agent_session,
        conversation_id: socket.assigns.agent_conversation_id,
        entry_id: entry_id,
        command: command
      })
      |> assign(:date_change_return_focus, "agent-prepared-#{entry_id}")
      |> put_date_change_dates(dates)
      |> review_date_change()
    else
      assign(socket, :agent_notice, @prepared_missing_notice)
    end
  end

  # One receipt per applied handoff: the exact reviewed command is compared with
  # the proposal inside the originating conversation (INV-7). Everything that can
  # fail here is presentation - the database write already succeeded - so a stale,
  # reset or dead origin never turns the apply into an error and never touches
  # another entry. An edited command leaves the card unconfirmed and says so.
  defp record_prepared_applied(
         %{assigns: %{date_change_origin: nil, extension_origin: nil}} = socket,
         _command
       ),
       do: socket

  defp record_prepared_applied(%{assigns: assigns} = socket, command) do
    origin = assigns.date_change_origin || assigns.extension_origin

    case Agents.record_applied(
           origin.session_pid,
           origin.conversation_id,
           origin.entry_id,
           command
         ) do
      :ok ->
        socket

      {:error, :command_changed} ->
        assign(socket, :agent_notice, @prepared_edited_notice)

      _stale_or_ended ->
        socket
    end
  end

  # The handoff returns focus to the prepared card that opened the drawer - a
  # stable focusable container that outlives its Review button. A conversation
  # reset (this tab or another) removes the card while the drawer is open, so the
  # surviving composer, or the header open button when the panel is closed,
  # receives focus instead.
  defp restore_agent_return_focus(
         %{
           assigns: %{date_change_origin: %{entry_id: entry_id, conversation_id: conversation_id}}
         } =
           socket
       ) do
    card_id = "agent-prepared-#{entry_id}"

    if socket.assigns.date_change_return_focus == card_id and
         conversation_id != socket.assigns.agent_conversation_id do
      assign(socket, :date_change_return_focus, surviving_agent_focus(socket))
    else
      socket
    end
  end

  defp restore_agent_return_focus(socket), do: socket

  defp surviving_agent_focus(socket) do
    if socket.assigns.agent_open?, do: "agent-composer-input", else: "agent-helper-open"
  end

  # The date-change command evaluates every target through `ServiceDates`, so an
  # identity whose retained range cannot be read never enters the drawer as a target:
  # it has no readable date set to stop or run, and its repair action is the import
  # link on the list. The identity itself stays listed with its name and usage.
  defp snapshot_sources(summaries) do
    summaries
    |> Enum.reject(& &1.coverage_error)
    |> Map.new(fn summary ->
      {summary.service_id,
       %{
         service_id: summary.service_id,
         name: summary.name || summary.service_id,
         trip_count: summary.trip_count,
         fingerprint: summary.fingerprint,
         dates: MapSet.new(summary.active_dates || [])
       }}
    end)
  end

  defp assign_date_change_form(socket, mode, values) do
    defaults = %{
      "mode" => mode,
      "date" => "",
      "date_from" => "",
      "date_to" => "",
      "date_add" => ""
    }

    assign(socket, :date_change_form, to_form(Map.merge(defaults, values), as: :date_change))
  end

  # A form event arrives nested under the form name; a bare input event arrives flat.
  defp date_change_params(params) do
    case params["date_change"] do
      nested when is_map(nested) -> Map.merge(params, nested)
      _other -> params
    end
  end

  defp update_date_change_dates(socket, params) do
    mode = allowlisted(params["mode"], @date_change_mode_keys, socket.assigns.date_change_mode)

    previous_dates =
      if mode == socket.assigns.date_change_mode, do: socket.assigns.date_change_dates, else: []

    socket =
      socket
      |> assign(:date_change_mode, mode)
      |> assign_date_change_form(
        mode,
        Map.take(params, ["date", "date_from", "date_to", "date_add"])
      )

    case collect_dates(mode, Map.put(params, "selected_dates", previous_dates)) do
      {:ok, dates} ->
        put_date_change_dates(socket, dates)

      {:error, field, message} ->
        socket
        |> assign(:date_change_dates, [])
        |> assign(:date_change_errors, %{field => message})
        |> assign(:date_change_review, nil)
    end
  end

  defp collect_dates("single", params) do
    case params["date"] do
      value when value in [nil, ""] -> {:ok, []}
      value -> single_date(value)
    end
  end

  defp collect_dates("range", params) do
    first = params["date_from"] || ""
    last = params["date_to"] || ""

    cond do
      String.trim(first) == "" and String.trim(last) == "" -> {:ok, []}
      String.trim(first) == "" -> {:error, "date_from", "Choose the first date of the range."}
      String.trim(last) == "" -> {:error, "date_to", "Choose the last date of the range."}
      true -> range_dates(first, last)
    end
  end

  defp collect_dates("several", params), do: {:ok, params["selected_dates"] || []}

  defp collect_dates(_mode, _params), do: {:ok, []}

  defp single_date(value) do
    case parse_date(value) do
      {:ok, date} -> {:ok, [date]}
      :error -> {:error, "date", "Enter a valid date, using YYYY-MM-DD."}
    end
  end

  defp range_dates(first, last) do
    with {:ok, first_date} <- single_date(first),
         {:ok, last_date} <- single_date(last) do
      [first_date, last_date] = [hd(first_date), hd(last_date)]

      if Date.compare(last_date, first_date) == :lt do
        {:error, "date_to", "Choose a last date on or after the first date."}
      else
        {:ok, Enum.to_list(Date.range(first_date, last_date))}
      end
    else
      {:error, _field, message} -> {:error, "date_from", message}
    end
  end

  defp put_date_change_dates(socket, dates) do
    dates = dates |> Enum.uniq() |> Enum.sort(Date)

    socket
    |> assign(:date_change_dates, dates)
    |> assign(:date_change_errors, %{})
    |> assign(:date_change_review, nil)
    |> assign_default_removals(dates)
  end

  # Defaults follow the selected dates until the reviewer chooses calendars by
  # hand; after that the manual selection is kept while the rest stays unchanged.
  defp assign_default_removals(%{assigns: %{date_change_manual?: true}} = socket, _dates),
    do: socket

  defp assign_default_removals(socket, dates) do
    assign(
      socket,
      :date_change_remove,
      default_removals(socket.assigns.date_change_sources, dates)
    )
  end

  defp default_removals(sources, dates) do
    sources
    |> Enum.filter(fn {_service_id, source} ->
      Enum.any?(dates, &MapSet.member?(source.dates, &1))
    end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp add_date_change_date(socket, params) do
    case parse_date(params["date_add"]) do
      {:ok, date} ->
        socket
        |> assign(:date_change_errors, %{})
        |> put_date_change_dates(socket.assigns.date_change_dates ++ [date])

      :error ->
        date_change_error(socket, "date_add", "Choose a valid date, using YYYY-MM-DD.")
    end
  end

  defp toggle_date_change_target(socket, group, service_id) do
    cond do
      group not in ["remove", "add"] ->
        socket

      not Map.has_key?(socket.assigns.date_change_sources, service_id) ->
        date_change_error(socket, "targets", "That calendar is not in this service version.")

      group == "remove" ->
        socket
        |> assign(:date_change_manual?, true)
        |> assign(:date_change_errors, %{})
        |> assign(
          :date_change_remove,
          toggle(MapSet.new(socket.assigns.date_change_remove), service_id)
        )

      true ->
        socket
        |> assign(:date_change_errors, %{})
        |> assign(
          :date_change_add,
          toggle(MapSet.new(socket.assigns.date_change_add), service_id)
        )
    end
  end

  defp toggle(set, service_id) do
    if MapSet.member?(set, service_id),
      do: MapSet.delete(set, service_id),
      else: MapSet.put(set, service_id)
  end

  defp review_date_change(socket) do
    dates = socket.assigns.date_change_dates
    remove_from = socket.assigns.date_change_remove |> MapSet.to_list() |> Enum.sort()
    add_to = socket.assigns.date_change_add |> MapSet.to_list() |> Enum.sort()

    cond do
      map_size(socket.assigns.date_change_errors) > 0 ->
        socket

      dates == [] ->
        date_change_error(socket, "date", "Choose at least one date to change.")

      remove_from == [] and add_to == [] ->
        date_change_error(socket, "targets", "Choose at least one calendar to change.")

      Enum.any?(remove_from, &(&1 in add_to)) ->
        date_change_error(
          socket,
          "targets",
          "A calendar cannot be stopped and run on the same date. Uncheck it in one group."
        )

      true ->
        command = {:date_change, dates, remove_from, add_to}
        audit = audit_context(socket)

        fingerprints =
          target_fingerprints(socket.assigns.date_change_sources, remove_from ++ add_to)

        case Gtfs.review_calendar_change(command, fingerprints, audit) do
          {:ok, review} ->
            socket
            |> assign(:date_change_errors, %{})
            |> assign(:date_change_review, %{
              command: command,
              fingerprint: review.fingerprint,
              affected_service_ids: review.affected_service_ids,
              active_date_count: review.active_date_count,
              selected_dates: dates,
              changed_count: review_changed_count(review.changes),
              warnings: review.warnings,
              remove_from: remove_from,
              add_to: add_to
            })

          {:error, reason} ->
            date_change_error(socket, "targets", review_error_message(reason))
        end
    end
  end

  # Only the snapshot's own service IDs can contribute a fingerprint, and every
  # target must carry one: a replaced or forged calendar never reaches a write.
  defp target_fingerprints(sources, service_ids) do
    Map.new(service_ids, fn service_id ->
      {service_id, sources |> Map.fetch!(service_id) |> Map.fetch!(:fingerprint)}
    end)
  end

  defp apply_date_change(socket) do
    case socket.assigns.date_change_review do
      %{command: command, fingerprint: fingerprint} ->
        socket = assign(socket, :date_change_pending?, true)

        case Gtfs.apply_calendar_change(command, fingerprint, audit_context(socket)) do
          {:ok, result} ->
            socket
            |> assign(:date_change_pending?, false)
            |> assign(:date_change_status, date_change_result_message(result))
            |> record_prepared_applied(command)
            |> close_date_change()
            |> reload_calendars()

          {:error, reason} ->
            socket
            |> assign(:date_change_pending?, false)
            |> assign(:date_change_review, nil)
            |> date_change_error("targets", review_error_message(reason))
        end

      nil ->
        assign(socket, :date_change_pending?, false)
    end
  end

  defp reload_calendars(socket) do
    send(self(), :load_calendars)
    assign(socket, :calendars_state, :refreshing)
  end

  defp date_change_result_message(%{changed_count: 0}) do
    "No change was needed: those dates already matched the reviewed result."
  end

  defp date_change_result_message(result) do
    count = length(result.affected_service_ids)

    "Applied the date change to #{count} #{if count == 1, do: "calendar", else: "calendars"} · #{result.changed_count} rows changed."
  end

  defp review_error_message(:stale_review) do
    "This list changed in another session. Your dates and calendars are still here; refresh the drawer and review again."
  end

  defp review_error_message(reason), do: write_error_message(reason)

  defp date_change_error(socket, field, message) do
    socket
    |> assign(:date_change_errors, %{field => message})
    |> assign(:date_change_review, nil)
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

  defp write_error_message(:stale_review) do
    "These calendars changed in another session. Your selection is still here; review again to see the current result."
  end

  defp write_error_message(:forbidden) do
    "You no longer have permission to change these calendars."
  end

  defp write_error_message(:not_found) do
    "One of these calendars is no longer available in this service version."
  end

  defp write_error_message(:unavailable) do
    "The database is temporarily unavailable. Your selection is still here."
  end

  defp write_error_message(:invalid_command) do
    "That change is not valid for these calendars."
  end

  defp write_error_message(_reason), do: "The date change could not be saved."

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  ## URL state

  defp assign_filter_form(socket) do
    assign(
      socket,
      :filter_form,
      to_form(%{"search" => socket.assigns.search, "status" => socket.assigns.status})
    )
  end

  defp to_query(assigns, params, sort_by \\ nil, sort_dir \\ nil) do
    %{}
    |> put_param("search", params["search"] || assigns.search, "")
    |> put_param("status", params["status"] || assigns.status, "all")
    |> put_param("range", params["range"] || assigns.range, "whole")
    |> put_param("sort_by", sort_by || assigns.sort_by, "name")
    |> put_param("sort_dir", sort_dir || assigns.sort_dir, "asc")
  end

  # The timeline range is a view of the same snapshot, not a filter, so it survives
  # a filter change and the filter state survives a range change.
  defp range_path(assigns, range),
    do: calendars_path(assigns, to_query(assigns, %{"range" => range}))

  defp calendars_path(assigns, query, version_id \\ nil) do
    version_id = version_id || assigns.current_gtfs_version.id

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

  defp format_date(date), do: Calendar.strftime(date, "%b %-d, %Y")

  defp format_day(date), do: Calendar.strftime(date, "%a, %b %-d")

  @badge_tones %{
    success: "bg-success-bg text-success-fg",
    warning: "bg-warning-bg text-warning-fg",
    neutral: "bg-canvas text-muted"
  }

  # The status says the one fact about the calendar's dates that needs a decision, in the
  # order the domain summary ranks them. Only a running calendar is green: that is the
  # design system's "Active", and every other state is a warning or neutral.
  defp badge(%{status: %{ended?: true}}), do: {:neutral, "Ended"}

  defp badge(%{status: %{ends_soon?: true, days_remaining: 0}}), do: {:warning, "Ends today"}

  defp badge(%{status: %{ends_soon?: true, days_remaining: days}}),
    do: {:warning, "Ends in #{days} #{if days == 1, do: "day", else: "days"}"}

  defp badge(%{status: %{no_service?: true}}), do: {:warning, "No service"}

  defp badge(%{status: %{used_by_trips?: false}}), do: {:neutral, "Not used by trips"}
  defp badge(%{status: %{active_today?: true}}), do: {:success, "Runs today"}
  defp badge(_summary), do: {:neutral, "Scheduled"}

  # Why "today" and the ending-soon dates are read in UTC: the version's agencies gave no
  # single usable time zone.
  defp zone_fallback_text(:conflicting),
    do: "The agencies use different time zones, so “today” and ending-soon dates use UTC."

  defp zone_fallback_text(:invalid),
    do: "The agency time zone isn’t a valid time zone, so “today” and ending-soon dates use UTC."

  defp zone_fallback_text(_missing),
    do: "The agency time zone is missing, so “today” and ending-soon dates use UTC."

  defp gap_label(%{first_date: date, last_date: date}), do: format_date(date)

  defp gap_label(%{first_date: first, last_date: last}),
    do: "#{format_date(first)} – #{format_date(last)}"

  defp result_count(%{constraints?: true} = assigns) do
    "#{length(assigns.calendars)} of #{assigns.counts.calendars} calendars"
  end

  defp result_count(assigns), do: "#{assigns.counts.calendars} calendars"

  ## Selection presentation

  # The select-all control reads as checked only when every matching selectable row is
  # already selected, the same rule the packaged reference uses for its header checkbox.
  defp select_all_selected?(assigns) do
    selectable =
      assigns.calendars
      |> Enum.filter(&is_nil(&1.coverage_error))
      |> Enum.map(& &1.service_id)
      |> MapSet.new()

    MapSet.size(selectable) > 0 and MapSet.equal?(selectable, assigns.selected_service_ids)
  end

  defp selection_count_label(1), do: "1 calendar selected"
  defp selection_count_label(count), do: "#{count} calendars selected"

  ## Combination presentation

  defp combination_scope(assigns) do
    case assigns.current_gtfs_version do
      %{name: name} when is_binary(name) -> name
      _version -> "this service version"
    end
  end

  # Opening the review writes nothing, so the drawer says what it is: a no-op offers only
  # Close, a pending confirmation states the move it is performing, a review that needs a
  # refresh states that nothing was combined, and every other review says that nothing has
  # changed until it is combined.
  defp combination_footer_note(assigns) do
    cond do
      assigns.combine_pending? -> pending_combination_note(assigns)
      assigns.combine_refresh_required? -> "Nothing was combined."
      CalendarComponents.combination_nothing?(assigns.combine_review) -> "Nothing to combine."
      true -> "Nothing changes until you combine."
    end
  end

  defp combine_submit_label(assigns) do
    if assigns.combine_pending? do
      "Combining…"
    else
      "Combine #{length(assigns.combine_rows)} calendars"
    end
  end

  # A review with nothing to do offers only a way out, so its exit is Close; every other
  # review is one the reviewer can walk away from, which is Cancel.
  defp combine_exit_label(assigns) do
    if CalendarComponents.combination_nothing?(assigns.combine_review),
      do: "Close",
      else: "Cancel"
  end

  # The status banner takes the tone of the state it reports: a missing answer and a refusal are
  # errors, a stale review and an unconfirmed confirmation are warnings the reviewer must resolve,
  # and a refreshed review is information.
  defp combine_status_kind(%{combine_status: %{kind: kind}}) do
    case kind do
      :missing -> "error"
      :failed -> "error"
      :stale -> "warning"
      :unconfirmed -> "warning"
      _status -> "info"
    end
  end

  ## Date-change presentation

  defp date_change_remove_options(assigns) do
    assigns.date_change_sources
    |> Map.values()
    |> Enum.filter(fn source ->
      MapSet.member?(assigns.date_change_remove, source.service_id) or
        Enum.any?(assigns.date_change_dates, &MapSet.member?(source.dates, &1))
    end)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  defp date_change_add_options(assigns) do
    assigns.date_change_sources
    |> Map.values()
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  defp date_change_label([]), do: "No dates selected"

  defp date_change_label([date]), do: Calendar.strftime(date, "%a, %b %-d, %Y")

  defp date_change_label([first | _rest] = dates) do
    "#{length(dates)} dates · #{format_date(first)} – #{format_date(List.last(dates))}"
  end

  # The reviewed change count is the domain's real per-row count: a plan set for
  # one calendar returns its own changes map, several calendars return the
  # aggregate map, and any other shape counts as no change.
  defp review_changed_count(%{changed_count: count}) when is_integer(count), do: count

  defp review_changed_count(%{calendars: calendars}) when is_map(calendars) do
    calendars
    |> Enum.map(fn {_service_id, calendar} -> Map.get(calendar, :changed_count, 0) end)
    |> Enum.sum()
  end

  defp review_changed_count(_changes), do: 0

  defp date_change_review_lines(assigns) do
    date_change_lines(assigns.date_change_review, assigns.date_change_sources)
  end

  # Every reviewed line names the calendar, the dates it is actually changed on, its real
  # trip count and whether the reviewed command changes it at all, so the drawer never implies
  # a write that the atomic command would skip.
  defp date_change_lines(review, sources) do
    changed = MapSet.new(review.affected_service_ids)
    dates = review.selected_dates

    Enum.map(review.remove_from, &target_line(:stop, &1, dates, sources, changed)) ++
      Enum.map(review.add_to, &target_line(:run, &1, dates, sources, changed))
  end

  defp target_line(kind, service_id, dates, sources, changed) do
    source = Map.fetch!(sources, service_id)
    changes? = MapSet.member?(changed, service_id)

    hit =
      case kind do
        :stop -> Enum.filter(dates, &MapSet.member?(source.dates, &1))
        :run -> Enum.reject(dates, &MapSet.member?(source.dates, &1))
      end

    %{
      kind: kind,
      name: source.name,
      trips: source.trip_count,
      changes?: changes?,
      dates: if(changes? and hit != [], do: hit, else: dates)
    }
  end

  defp line_predicate(%{kind: :stop, changes?: true} = line),
    do: "stops running on #{line_dates(line)}."

  defp line_predicate(%{kind: :stop} = line),
    do: "already has no service on #{line_these(line)}."

  defp line_predicate(%{kind: :run, changes?: true} = line),
    do: "runs on #{line_dates(line)}."

  defp line_predicate(%{kind: :run} = line), do: "already runs on #{line_these(line)}."

  defp line_effect(%{changes?: false}), do: "Nothing changes."
  defp line_effect(%{kind: :stop, trips: trips}), do: "#{trips_label(trips)} affected."
  defp line_effect(%{kind: :run, trips: trips}), do: "#{trips_label(trips)} will run."

  defp trips_label(1), do: "1 trip"
  defp trips_label(count), do: "#{count} trips"

  defp line_dates(%{dates: [date]}), do: format_day(date)
  defp line_dates(%{dates: dates}), do: "#{length(dates)} dates"

  defp line_these(%{dates: [_date]}), do: "this date"
  defp line_these(_line), do: "these dates"

  defp rows_change_label(1), do: "1 row changes"
  defp rows_change_label(count), do: "#{count} rows change"

  defp calendars_label(1), do: "1 calendar"
  defp calendars_label(count), do: "#{count} calendars"

  defp warning_text(%{reason: :no_service}), do: "No service would remain on any selected date."

  defp warning_text(%{reason: :ends_soon, last_date: date, days_remaining: days}),
    do:
      "Service ends #{format_date(date)} · #{days} #{if days == 1, do: "day", else: "days"} away."

  defp warning_text(%{reason: :ended, last_date: date}),
    do: "Service ended #{format_date(date)}."

  defp warning_text(%{reason: :outside_range, date: date, exception: exception}),
    do: "#{format_date(date)} is outside the regular range for a #{exception} date."

  defp warning_text(%{reason: :redundant_addition, date: date}),
    do: "#{format_date(date)} already runs on the regular schedule."

  defp warning_text(%{reason: :removal_on_nonservice_day, date: date}),
    do: "#{format_date(date)} already had no regular service."

  defp warning_text(_warning), do: "This change needs review."

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
      <div id="calendars-page" class="ds-page">
        <.header>
          Calendars
          <:subtitle>
            See which days each service runs in {combination_scope(assigns)}, then fix holidays,
            closures and duplicates.
          </:subtitle>
          <%!-- With no calendars yet, the first-use panel carries the one way forward. --%>
          <:actions :if={@calendars_state in [:ready, :refreshing] and not @calendars_empty?}>
            <.button
              id="agent-helper-open"
              type="button"
              phx-click="agent_open"
              aria-expanded={to_string(@agent_open?)}
              aria-controls="agent-panel"
              variant="quiet"
              class="min-h-11"
            >
              Open helper
            </.button>
            <.button
              id="calendars-create"
              navigate={create_path(assigns)}
              variant="secondary"
              class="min-h-11"
            >
              <.icon name="hero-plus" class="size-4" /> Create calendar
            </.button>
            <.button
              id="calendar-date-change"
              type="button"
              phx-click="open_date_change"
              class="min-h-11"
            >
              Change service on a date
            </.button>
          </:actions>
        </.header>

        <%!--
        The panel's focus listener belongs to this persistent wrapper, not to the panel: the
        closing panel cannot own a handler that runs after its own removal. The grid gives the
        workspace the full width while the panel is closed and a fixed 24rem column while it is
        open, and the workspace column is hidden at phone width so the panel replaces the list. --%>
        <div
          id="calendar-helper-focus"
          phx-hook=".CalendarHelperFocus"
          class={["lg:grid lg:gap-6", @agent_open? && "lg:grid-cols-[minmax(0,1fr)_24rem]"]}
        >
          <div class={@agent_open? && "hidden lg:block"}>
            <%!--
        The combination transport hook owns this page's connection lifecycle, and the notice it reveals
        lives here rather than inside the drawer: the shared dialog hook closes a modal when the socket
        drops, so an in-drawer notice could never be seen by the reviewer it is meant to warn. The
        notice is pre-rendered by the server and only revealed by the hook (its own subtree is never
        patched), and the hook never computes a date, decides a review or retries a confirmation. --%>
            <div
              id="calendar-combine-transport"
              phx-hook="CalendarCombination"
              data-combine-dispatched={to_string(@combine_dispatched?)}
              data-combine-pending={to_string(@combine_pending?)}
            >
              <div id="calendar-combine-connection" phx-update="ignore" role="status" hidden>
                <div class="mb-5 flex items-start gap-3 rounded-control bg-warning-bg px-4 py-3 text-warning-fg">
                  <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
                  <div class="min-w-0 text-sm">
                    <p class="font-bold">Connection lost. Reconnecting…</p>
                    <p class="mt-0.5" data-combine-connection="idle">
                      Nothing has been sent, and your choices are kept. Combine is available again when
                      the connection returns.
                    </p>
                    <p class="mt-0.5" data-combine-connection="dispatched" hidden>
                      Your confirmation was sent and this page has no answer for it, so its outcome is
                      unconfirmed: it may have been applied. When the connection returns, the list
                      reloads from the server. Review the current calendars before you confirm again.
                    </p>
                  </div>
                </div>
              </div>
            </div>

            <div
              :if={@calendars_state in [:ready, :refreshing]}
              id="calendars-notices"
              class="grid gap-3 has-[*]:mb-5"
            >
              <CalendarComponents.combination_success
                :if={@combine_success}
                id="calendar-combine-success"
                success={@combine_success}
              />

              <CalendarComponents.coverage_invalid
                invalid={@invalid_calendars}
                version_id={@current_gtfs_version.id}
              />

              <.message
                :if={@date_change_status}
                id="calendars-date-change-status"
                kind="success"
                title={@date_change_status}
              />

              <.message
                :if={@extension_success}
                id="calendars-extension-status"
                kind="success"
                title={@extension_success}
              />

              <.message
                :if={(@zone && @zone.fallback?) and not @calendars_empty?}
                id="calendars-timezone-fallback"
                kind="warning"
                title="Today and expiry use UTC"
              >
                {zone_fallback_text(@zone.fallback_reason)}
              </.message>

              <div
                :if={@calendars_state == :ready and is_list(@gaps) and @gaps != []}
                id="calendars-feed-gap"
              >
                <.message kind="warning" title={"No service on any calendar: #{gap_label(hd(@gaps))}"}>
                  This may be intentional. If trips should run, add service for that date.
                  <span :if={length(@gaps) > 1} class="mt-1 block">
                    {length(@gaps)} service gaps exist between the first and last active dates.
                  </span>
                  <:action>
                    <.button
                      id="calendars-feed-gap-review"
                      type="button"
                      phx-click="open_date_change"
                      phx-value-date={Date.to_iso8601(hd(@gaps).first_date)}
                      variant="secondary"
                      class="min-h-11"
                    >
                      Review date
                    </.button>
                  </:action>
                </.message>
              </div>
            </div>

            <div
              :if={@calendars_state == :loading}
              id="calendars-loading"
              role="status"
              aria-busy="true"
              class="overflow-clip rounded-card border border-subtle bg-white"
            >
              <div class="flex gap-3 border-b border-subtle px-4 py-4 md:px-5" aria-hidden="true">
                <span class="h-11 flex-1 rounded-badge bg-canvas"></span>
                <span class="h-11 w-[212px] rounded-badge bg-canvas max-md:hidden"></span>
                <span class="h-11 w-[190px] rounded-badge bg-canvas max-md:hidden"></span>
              </div>
              <p class="flex h-[52px] items-center border-b border-subtle px-4 text-[13px] text-muted md:px-5">
                Loading calendars…
              </p>
              <div
                :for={_row <- 1..6}
                aria-hidden="true"
                class="flex h-[68px] items-center gap-6 border-b border-subtle px-5 last:border-b-0 motion-safe:animate-pulse"
              >
                <span class="size-[18px] rounded-badge bg-canvas"></span>
                <span class="grid w-[200px] gap-2">
                  <span class="h-3 w-32 rounded-badge bg-canvas"></span>
                  <span class="h-2.5 w-20 rounded-badge bg-canvas"></span>
                </span>
                <span class="h-3 flex-1 rounded-badge bg-canvas"></span>
                <span class="h-3 w-10 rounded-badge bg-canvas max-md:hidden"></span>
                <span class="h-5 w-24 rounded-badge bg-canvas max-md:hidden"></span>
              </div>
            </div>

            <div :if={@calendars_state == :unavailable} id="calendars-unavailable">
              <.message kind="error" title="Calendars couldn’t be loaded">
                Nothing was changed. Try again to see calendars for this service version.
                <:action>
                  <.button
                    id="calendars-retry"
                    type="button"
                    phx-click="retry"
                    variant="secondary"
                    class="min-h-11"
                  >
                    <.icon name="hero-arrow-path" class="size-4" /> Reload calendars
                  </.button>
                </:action>
              </.message>
            </div>

            <div :if={@calendars_state == :not_found} id="calendars-version-unavailable">
              <.message kind="info" title="Calendars aren’t available for this service version">
                Open a published version you can edit to review its calendars.
              </.message>
            </div>

            <div :if={@calendars_state in [:ready, :refreshing]}>
              <p
                :if={@calendars_state == :refreshing and @calendars_empty?}
                id="calendars-refreshing"
                role="status"
                class="text-sm text-muted"
              >
                Refreshing calendars…
              </p>

              <.first_use
                :if={@calendars_empty? and @calendars_state == :ready}
                id="calendars-first-use-empty"
                title={"No calendars in #{combination_scope(assigns)} yet"}
                icon="hero-calendar-days"
              >
                Calendars say which days each service runs, such as Weekday, Saturday, and Sunday &amp;
                holidays. Create your first calendar to start.
                <:action>
                  <.button id="calendars-create" navigate={create_path(assigns)} class="min-h-11">
                    <.icon name="hero-plus" class="size-4" /> Create calendar
                  </.button>
                </:action>
              </.first_use>

              <section
                :if={not @calendars_empty?}
                id="calendars-workbench"
                aria-label="Calendars"
                class="overflow-clip rounded-card border border-subtle bg-white"
              >
                <.form
                  for={@filter_form}
                  id="calendar-filter-form"
                  role="search"
                  phx-change="filters"
                  class="flex flex-wrap items-end gap-3 border-b border-subtle px-4 py-4 md:px-5"
                >
                  <div class="min-w-0 flex-1 basis-[220px]">
                    <.input
                      id="calendar-search"
                      field={@filter_form[:search]}
                      type="search"
                      label="Find a calendar"
                      placeholder="Name or service ID"
                      autocomplete="off"
                      phx-debounce="300"
                    />
                  </div>
                  <div class="min-w-0 flex-1 basis-[136px] md:w-[212px] md:flex-none">
                    <.input
                      id="calendar-status"
                      field={@filter_form[:status]}
                      type="select"
                      label="Show"
                      options={@status_options}
                    />
                  </div>
                  <div class="grid gap-1.5">
                    <span
                      id="calendar-coverage-range-label"
                      class="mb-1 text-[13px] font-[650] text-default"
                    >
                      Timeline
                    </span>
                    <div
                      id="calendar-coverage-range"
                      role="group"
                      aria-labelledby="calendar-coverage-range-label"
                      class="calendar-coverage-range"
                    >
                      <.link
                        :for={option <- @range_options}
                        id={"calendar-coverage-range-#{option.value}"}
                        patch={range_path(assigns, option.value)}
                        aria-current={
                          if @range == option.value or (@range == "all" and option.value == "whole"),
                            do: "true"
                        }
                        class="calendar-coverage-range-option"
                      >
                        {option.label}
                      </.link>
                    </div>
                  </div>
                </.form>

                <%!-- One row of fixed height: the result count, or the selection's actions once a
            calendar is ticked. Swapping them in place keeps the table from jumping. --%>
                <div id="calendar-summary" class="border-b border-subtle">
                  <div
                    :if={@calendars_state == :ready and MapSet.size(@selected_service_ids) > 0}
                    id="calendar-selection-bar"
                    class="flex min-h-[60px] flex-wrap items-center gap-x-3 gap-y-1 bg-selection px-4 py-1 text-[13px] md:px-5"
                  >
                    <p
                      id="calendar-selection-count"
                      role="status"
                      class="font-[650] tabular-nums text-strong"
                    >
                      {selection_count_label(MapSet.size(@selected_service_ids))}
                    </p>
                    <.button
                      id="calendar-combine-open"
                      type="button"
                      phx-click="open_combine"
                      disabled={MapSet.size(@selected_service_ids) < 2 or @invalid_calendars != []}
                      variant="secondary"
                      class="min-h-11"
                    >
                      Combine calendars
                    </.button>
                    <p
                      :if={MapSet.size(@selected_service_ids) == 1}
                      id="calendar-combine-hint"
                      class="text-muted"
                    >
                      Select one more calendar to combine.
                    </p>
                    <p
                      :if={@invalid_calendars != []}
                      id="calendar-combine-unavailable"
                      class="text-muted"
                    >
                      Combining is unavailable until the calendar with an end date before its start date is fixed. Use Fix dates on that calendar.
                    </p>
                    <p
                      :if={@combine_error}
                      id="calendar-combine-error"
                      role="alert"
                      class="font-[650] text-error-fg"
                    >
                      {@combine_error}
                    </p>
                    <.button
                      id="calendar-clear-selection"
                      type="button"
                      phx-click="clear_calendar_selection"
                      variant="quiet"
                      class="ml-auto min-h-11 text-action hover:underline"
                    >
                      Clear selection
                    </.button>
                  </div>

                  <div
                    :if={@calendars_state != :ready or MapSet.size(@selected_service_ids) == 0}
                    class="flex min-h-[60px] flex-wrap items-center gap-x-3 gap-y-1 px-4 py-1 text-[13px] md:px-5"
                  >
                    <p
                      id="result-count"
                      role="status"
                      aria-live="polite"
                      class="font-[650] tabular-nums text-strong"
                    >
                      {result_count(assigns)}
                    </p>
                    <ul id="calendar-counts" class="flex flex-wrap gap-x-3 tabular-nums">
                      <li
                        id="calendar-counts-item-run-today"
                        data-key="run-today"
                        class={@counts.run_today > 0 && "text-success-fg"}
                      >
                        {@counts.run_today} run today
                      </li>
                      <li
                        id="calendar-counts-item-ending-soon"
                        data-key="ending-soon"
                        class={if(@counts.ending_soon > 0, do: "text-warning-fg", else: "text-muted")}
                      >
                        {@counts.ending_soon} ending soon
                      </li>
                    </ul>
                    <span :if={@today} id="calendars-today" class="text-muted">
                      Today · {format_date(@today)}
                    </span>
                    <p
                      :if={
                        @calendars_state == :ready and not @constraints? and @calendars != [] and
                          @invalid_calendars == []
                      }
                      id="calendar-selection-hint"
                      class="text-muted max-md:hidden"
                    >
                      Select two or more calendars to combine them.
                    </p>
                    <p
                      :if={@calendars_state == :ready and @invalid_calendars != []}
                      id="calendar-combine-unavailable"
                      class="text-muted"
                    >
                      Combining is unavailable until the calendar with an end date before its start date is fixed. Use Fix dates on that calendar.
                    </p>
                    <p
                      :if={@calendars_state == :ready and @combine_error}
                      id="calendar-combine-error"
                      role="alert"
                      class="font-[650] text-error-fg"
                    >
                      {@combine_error}
                    </p>
                    <.button
                      :if={@constraints?}
                      id="calendar-clear-filters"
                      type="button"
                      phx-click="clear_filters"
                      variant="quiet"
                      class="min-h-11 text-action hover:underline"
                    >
                      Clear filters
                    </.button>
                    <span class="ml-auto flex items-center gap-3">
                      <span
                        :if={@calendars_state == :refreshing}
                        id="calendars-refreshing"
                        role="status"
                        class="text-muted"
                      >
                        Refreshing. The list stays as it was.
                      </span>
                      <.button
                        id="calendar-refresh"
                        type="button"
                        phx-click="refresh"
                        disabled={@calendars_state == :refreshing}
                        variant="quiet"
                        class="min-h-11 text-action hover:underline disabled:text-muted disabled:no-underline"
                      >
                        <.icon
                          name="hero-arrow-path"
                          class={[
                            "size-4",
                            @calendars_state == :refreshing && "motion-safe:animate-spin"
                          ]}
                        />
                        {if @calendars_state == :refreshing, do: "Refreshing…", else: "Refresh"}
                      </.button>
                    </span>
                  </div>
                </div>

                <div
                  :if={
                    @coverage != nil and
                      ((@range == "whole" and @coverage.clipped?) or
                         (@range == "all" and @long_history?))
                  }
                  id="calendar-coverage-window"
                  class="flex flex-wrap items-center gap-x-2 border-b border-subtle px-4 text-[13px] text-muted md:px-5"
                >
                  <span :if={@range == "whole"}>
                    Timeline starts {format_date(@coverage.first_date)}; earlier service since {format_date(
                      @screen.horizon.first_date
                    )} is hidden.
                  </span>
                  <span :if={@range == "all"}>Every year of this version is shown.</span>
                  <.link
                    :if={@range == "whole"}
                    id="calendar-coverage-show-all"
                    patch={range_path(assigns, "all")}
                    class="inline-flex min-h-11 items-center font-[650] text-action hover:underline"
                  >
                    Show all years
                  </.link>
                  <.link
                    :if={@range == "all"}
                    id="calendar-coverage-restore"
                    patch={range_path(assigns, "whole")}
                    class="inline-flex min-h-11 items-center font-[650] text-action hover:underline"
                  >
                    Show recent years
                  </.link>
                </div>

                <div
                  :if={@filtered_empty? and @calendars_state == :ready}
                  id="calendars-filtered-empty"
                  class="px-5 py-12 text-center"
                >
                  <h2 class="font-sans text-base font-bold tracking-normal text-strong">
                    No calendars match these filters
                  </h2>
                  <p class="mx-auto mt-1.5 max-w-[46ch] text-sm text-muted">
                    Try another name, or show all calendars.
                  </p>
                  <.button
                    id="calendars-clear-filters"
                    type="button"
                    phx-click="clear_filters"
                    variant="secondary"
                    class="mt-5 min-h-11"
                  >
                    Clear filters
                  </.button>
                </div>

                <div :if={@calendars != []} id="calendars-results">
                  <.calendars_table
                    rows={@streams.calendars}
                    coverage={@coverage}
                    sort_by={@sort_by}
                    sort_dir={@sort_dir}
                    all_selected?={select_all_selected?(assigns)}
                    selected_ids={@selected_service_ids}
                    marked_ids={@combine_highlight}
                    version_id={@current_gtfs_version.id}
                    scope={combination_scope(assigns)}
                  />
                  <CalendarComponents.coverage_legend />
                </div>
              </section>

              <p
                :if={not @calendars_empty?}
                id="calendars-shared-note"
                class="mt-4 text-[13px] text-muted"
              >
                Routes share calendars. Changing a calendar changes every trip that uses it.
              </p>

              <%!-- The approval is the editor's own sentence, entered here and copied into the
              helper session's context. Nothing is written by this form; the helper prepares a
              command from it and only a reviewed native apply changes the calendar. --%>
              <section
                :if={@calendars_state in [:ready, :refreshing] and not @calendars_empty?}
                id="calendar-extension-approval"
                aria-labelledby="calendar-extension-approval-title"
                class="mt-4 rounded-card border border-subtle bg-white p-4 sm:p-5"
              >
                <h2 id="calendar-extension-approval-title" class="text-base font-bold text-strong">
                  Approve a calendar extension
                </h2>
                <p class="mt-1 text-[13px] text-muted">
                  Approve running a weekly calendar past its current end date. The helper can prepare
                  the extension from this approval; you still review the result and apply it.
                </p>

                <.message
                  :if={@extension_notice}
                  id="calendar-extension-approved"
                  kind="success"
                  title={@extension_notice}
                />

                <.message
                  :if={@extension_errors != %{}}
                  id="calendar-extension-errors"
                  tabindex="-1"
                  kind="error"
                  title={Enum.join(Map.values(@extension_errors), " ")}
                />

                <.form
                  for={@extension_form}
                  id="calendar-extension-form"
                  phx-hook="FormErrorFocus"
                  phx-change="extension_approval_change"
                  phx-submit="extension_approval"
                  class="mt-3 grid gap-4 sm:max-w-[560px]"
                >
                  <div class="max-w-[320px]">
                    <.input
                      id="calendar-extension-service"
                      field={@extension_form[:service_id]}
                      type="select"
                      label="Weekly calendar"
                      prompt="Choose a calendar"
                      options={
                        Enum.map(extension_options(assigns), &{extension_option(&1), &1.service_id})
                      }
                      errors={List.wrap(@extension_errors["service_id"])}
                    />
                  </div>
                  <div class="max-w-[220px]">
                    <.input
                      id="calendar-extension-end-date"
                      field={@extension_form[:end_date]}
                      type="date"
                      label="Run through"
                      errors={List.wrap(@extension_errors["end_date"])}
                    />
                  </div>
                  <div>
                    <.input
                      id="calendar-extension-approval-text"
                      field={@extension_form[:approval_text]}
                      type="textarea"
                      label="Why you are approving it"
                      maxlength="2000"
                      class="textarea min-h-20 w-full"
                      errors={List.wrap(@extension_errors["approval_text"])}
                    />
                  </div>
                  <div class="flex flex-wrap items-center gap-3">
                    <.button id="calendar-extension-approve" type="submit" class="min-h-11">
                      Approve extension
                    </.button>
                    <p class="text-[13px] text-muted">
                      Approving records this decision for the helper. It changes no service date.
                    </p>
                  </div>
                </.form>
              </section>
            </div>
          </div>

          <div
            :if={@agent_open?}
            class="flex min-w-0 lg:sticky lg:top-4 lg:max-h-[calc(100vh-2rem)]"
          >
            <.agent_panel
              id="agent-panel"
              title={@agent_title}
              intro={@agent_intro}
              examples={@agent_examples}
              scope_line={"Calendars · " <> @current_gtfs_version.name}
              status={@agent_status}
              entries={@streams.agent_entries}
              form={@agent_form}
              notice={@agent_notice}
              entries_empty?={@agent_entries_empty?}
            />
          </div>
        </div>

        <.drawer
          id="calendar-date-change-drawer"
          chrome="planner"
          open={@date_change_open?}
          pending={@date_change_pending?}
          on_close="close_date_change"
          title="Change service on a date"
          initial_focus={:first_field}
          return_focus_id={@date_change_return_focus}
          class="max-w-[560px]"
        >
          <:lede>Holidays, closures and one-off changes</:lede>
          <.form
            for={@date_change_form}
            id="calendar-date-change-form"
            phx-hook="CalendarDateChange"
            phx-change="date_change_form"
            phx-submit="date_change_add_date"
            class="flex min-h-0 flex-1 flex-col"
          >
            <.drawer_scroll>
              <p class="text-sm text-muted">
                Use a different schedule for a holiday, or stop service for a closure. This changes
                the published version, {combination_scope(assigns)}, so you review the result first.
              </p>

              <.message
                :if={@date_change_errors != %{}}
                id="calendar-date-change-error"
                kind="error"
                title={Enum.join(Map.values(@date_change_errors), " ")}
              />

              <CalendarComponents.date_selection
                id="calendar-date-change-dates"
                form={@date_change_form}
                mode={@date_change_mode}
                dates={@date_change_dates}
                errors={@date_change_errors}
                mode_options={@date_change_modes}
              />

              <fieldset
                :if={@date_change_review == nil}
                id="calendar-date-change-remove"
                class={[
                  "min-w-0 rounded-card border px-4 pb-3 pt-2",
                  if(@date_change_errors["targets"],
                    do: "border-2 border-error-line",
                    else: "border-subtle"
                  )
                ]}
              >
                <legend class="px-1 text-sm font-bold text-strong">Stop service on</legend>
                <p class="text-[13px] text-muted">
                  Calendars running on at least one of these dates are checked. Pick your own and
                  your choice stays when the dates change.
                </p>
                <ul class="mt-1">
                  <li
                    :for={source <- date_change_remove_options(assigns)}
                    id={"calendar-date-change-remove-#{URI.encode_www_form(source.service_id)}"}
                  >
                    <label class="flex min-h-11 cursor-pointer items-start gap-3 py-1.5">
                      <input
                        type="checkbox"
                        class="mt-0.5 size-[18px] shrink-0 cursor-pointer accent-action"
                        checked={MapSet.member?(@date_change_remove, source.service_id)}
                        phx-click="date_change_toggle"
                        phx-value-group="remove"
                        phx-value-service-id={source.service_id}
                        aria-label={"Stop service on the selected dates for #{source.name}"}
                      />
                      <span>
                        <span class="block text-sm font-[650] text-strong">{source.name}</span>
                        <span class="block text-[13px] text-muted">
                          <code class="font-mono">{source.service_id}</code>
                          · {trips_label(source.trip_count)}
                        </span>
                      </span>
                    </label>
                  </li>
                  <li
                    :if={date_change_remove_options(assigns) == []}
                    class="py-2 text-sm text-muted"
                  >
                    No calendar runs on these dates yet.
                  </li>
                </ul>
              </fieldset>

              <fieldset
                :if={@date_change_review == nil}
                id="calendar-date-change-add"
                class={[
                  "min-w-0 rounded-card border px-4 pb-3 pt-2",
                  if(@date_change_errors["targets"],
                    do: "border-2 border-error-line",
                    else: "border-subtle"
                  )
                ]}
              >
                <legend class="px-1 text-sm font-bold text-strong">
                  Run instead <span class="font-normal text-muted">(optional)</span>
                </legend>
                <p class="text-[13px] text-muted">
                  Choose every calendar that should run on these dates, such as Sunday &amp;
                  holidays. A calendar can’t be stopped and run on the same date.
                </p>
                <ul class="mt-1">
                  <li
                    :for={source <- date_change_add_options(assigns)}
                    id={"calendar-date-change-add-#{URI.encode_www_form(source.service_id)}"}
                  >
                    <label class="flex min-h-11 cursor-pointer items-start gap-3 py-1.5">
                      <input
                        type="checkbox"
                        class="mt-0.5 size-[18px] shrink-0 cursor-pointer accent-action"
                        checked={MapSet.member?(@date_change_add, source.service_id)}
                        phx-click="date_change_toggle"
                        phx-value-group="add"
                        phx-value-service-id={source.service_id}
                        aria-label={"Run #{source.name} on the selected dates"}
                      />
                      <span>
                        <span class="block text-sm font-[650] text-strong">{source.name}</span>
                        <span class="block text-[13px] text-muted">
                          <code class="font-mono">{source.service_id}</code>
                          · {trips_label(source.trip_count)}
                        </span>
                      </span>
                    </label>
                  </li>
                </ul>
              </fieldset>

              <div
                :if={@date_change_review == nil}
                id="calendar-date-change-summary"
                aria-live="polite"
                class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 rounded-card bg-canvas p-4 text-sm"
              >
                <div>
                  <h3 class="font-bold text-strong">Selected</h3>
                  <p id="calendar-date-change-selection">{date_change_label(@date_change_dates)}</p>
                  <p class="mt-1 text-muted">
                    Nothing changes until you review the result and apply it.
                  </p>
                </div>
                <.button
                  id="calendar-date-change-refresh"
                  type="button"
                  phx-click="date_change_refresh"
                  variant="quiet"
                  class="min-h-11 text-action hover:underline"
                >
                  <.icon name="hero-arrow-path" class="size-4" /> Refresh calendars
                </.button>
              </div>

              <div
                :if={@date_change_review != nil}
                id="calendar-date-change-review-panel"
                class="grid gap-3 rounded-card bg-canvas p-4"
              >
                <h3 class="text-base font-bold text-strong">Result after applying</h3>
                <p id="calendar-date-change-review-summary" class="text-sm font-[650] text-strong">
                  {date_change_label(@date_change_review.selected_dates)}
                </p>
                <ul id="calendar-date-change-review-lines" class="grid gap-2 text-sm">
                  <li
                    :for={line <- date_change_review_lines(assigns)}
                    class="flex items-start gap-2.5"
                  >
                    <span class={[
                      "mt-px inline-flex min-w-11 shrink-0 justify-center rounded-badge px-2 py-0.5 text-[13px] font-[650]",
                      if(line.kind == :stop,
                        do: "bg-warning-bg text-warning-fg",
                        else: "bg-success-bg text-success-fg"
                      )
                    ]}>
                      {if line.kind == :stop, do: "Stop", else: "Run"}{" "}
                    </span>
                    <span class="min-w-0">
                      <strong class="font-[650] text-strong">{line.name}</strong>
                      {line_predicate(line)}
                      <span class="text-muted">{line_effect(line)}</span>
                    </span>
                  </li>
                </ul>
                <p id="calendar-date-change-review-count" class="text-sm">
                  <span :if={@date_change_review.affected_service_ids != []}>
                    This changes <strong>{calendars_label(length(@date_change_review.affected_service_ids))}</strong>.
                  </span>
                  <span :if={@date_change_review.affected_service_ids == []}>
                    No calendar changes.
                  </span>
                  <span class="text-[13px] text-muted">
                    GTFS: {rows_change_label(@date_change_review.changed_count)}.
                  </span>
                </p>
                <.message
                  :if={@date_change_review.warnings != []}
                  id="calendar-date-change-warnings"
                  kind="warning"
                  title={"#{length(@date_change_review.warnings)} warnings to read first"}
                >
                  <ul class="grid gap-0.5">
                    <li :for={warning <- @date_change_review.warnings}>{warning_text(warning)}</li>
                  </ul>
                </.message>
              </div>
            </.drawer_scroll>

            <.drawer_footer>
              <.button
                id="calendar-date-change-cancel"
                type="button"
                phx-click="close_date_change"
                variant="secondary"
                class="min-h-11"
              >
                Cancel
              </.button>
              <.button
                :if={@date_change_review == nil}
                id="calendar-date-change-review"
                type="button"
                phx-click="date_change_review"
                class="min-h-11"
              >
                Review change
              </.button>
              <.button
                :if={@date_change_review != nil}
                id="calendar-date-change-back"
                type="button"
                phx-click="date_change_back"
                variant="secondary"
                class="min-h-11"
              >
                Change selection
              </.button>
              <.button
                :if={@date_change_review != nil}
                id="calendar-date-change-apply"
                type="button"
                phx-click={JS.dispatch("calendar:apply", to: "#calendar-date-change-form")}
                disabled={@date_change_pending?}
                class="min-h-11 min-w-[168px]"
              >
                {if @date_change_pending?, do: "Applying…", else: "Apply date change"}
              </.button>
            </.drawer_footer>
          </.form>
        </.drawer>

        <%!-- A confirmation whose answer was lost is resolved by re-reading the list, never by
        resending it. The notice lives here, outside the drawer, because the shared dialog hook
        closes a modal as soon as the socket drops. --%>
        <div
          id="calendar-extension-transport"
          phx-hook=".CalendarExtensionTransport"
          data-extension-dispatched={to_string(@extension_dispatched?)}
          data-extension-pending={to_string(@extension_pending?)}
        >
          <div id="calendar-extension-connection" phx-update="ignore" role="status" hidden>
            <div class="mb-5 flex items-start gap-3 rounded-control bg-warning-bg px-4 py-3 text-warning-fg">
              <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
              <div class="min-w-0 text-sm">
                <p class="font-bold">Connection lost. Reconnecting…</p>
                <p class="mt-0.5" data-extension-connection="idle" hidden>
                  Nothing has been sent. Your review is still here to confirm.
                </p>
                <p class="mt-0.5" data-extension-connection="dispatched" hidden>
                  Your confirmation was sent and this page has no answer for it, so nothing is
                  claimed about it. Refresh the review after the list reloads.
                </p>
              </div>
            </div>
          </div>
        </div>

        <.drawer
          id="calendar-extension-drawer"
          chrome="planner"
          open={@extension_open?}
          pending={@extension_pending?}
          on_close="extension_close"
          title="Review calendar extension"
          initial_focus={:first_field}
          return_focus_id={@extension_return_focus}
          class="max-w-[620px]"
        >
          <:lede>Approved end-date extension</:lede>
          <.form
            for={@extension_review_form}
            id="calendar-extension-review-form"
            phx-hook="FormErrorFocus"
            phx-change="extension_review_change"
            class="flex min-h-0 flex-1 flex-col"
          >
            <.drawer_scroll>
              <.message
                :if={@extension_status}
                id="calendar-extension-status"
                tabindex="-1"
                kind={extension_status_kind(assigns)}
                title={@extension_status.title}
              >
                {@extension_status.message}
              </.message>

              <div class="max-w-[220px]">
                <.input
                  id="calendar-extension-review-end-date"
                  field={@extension_review_form[:end_date]}
                  type="date"
                  label="Run through"
                  disabled={@extension_pending?}
                />
              </div>
              <p class="mt-2 text-[13px] text-muted">
                Changing this date changes the extension you apply. Your approval still applies to
                this calendar.
              </p>

              <Editor.extension_review
                :if={@extension_review}
                id="calendar-extension-impact"
                extension={@extension_review.extension}
                approval_text={@extension_review.approval_text}
              />
            </.drawer_scroll>

            <.drawer_footer>
              <.button
                id="calendar-extension-cancel"
                type="button"
                phx-click="extension_close"
                variant="secondary"
                class="min-h-11"
              >
                Cancel
              </.button>
              <.button
                :if={@extension_refresh_required?}
                id="calendar-extension-refresh"
                type="button"
                phx-click="extension_refresh"
                variant="secondary"
                class="min-h-11"
              >
                Refresh review
              </.button>
              <.button
                id="calendar-extension-apply"
                type="button"
                phx-click="extension_apply"
                disabled={@extension_pending? or @extension_refresh_required?}
                class="min-h-11 min-w-[168px]"
              >
                {if @extension_pending?, do: "Applying…", else: "Apply extension"}
              </.button>
            </.drawer_footer>
          </.form>
        </.drawer>

        <.drawer
          id="calendar-combine-drawer"
          chrome="planner"
          open={@combine_open?}
          pending={@combine_pending?}
          on_close="close_combine"
          title="Combine calendars"
          return_focus_id={@combine_return_focus_id}
          class="max-w-[760px]"
        >
          <:lede :if={@combine_review != nil}>
            <span id="calendar-combine-subtitle">
              {selection_count_label(length(@combine_rows))} · {combination_scope(assigns)}
            </span>
          </:lede>
          <.form
            :if={@combine_review != nil}
            for={@combine_form}
            id="calendar-combine-form"
            phx-hook="FormErrorFocus"
            phx-change="combine_change"
            phx-submit="combine_apply"
            class="flex min-h-0 flex-1 flex-col"
          >
            <.drawer_scroll>
              <.message
                :if={@combine_error}
                id="calendar-combine-drawer-error"
                kind="error"
                title={@combine_error}
              />

              <.message
                :if={@combine_status && @combine_status.kind != :pending}
                id="calendar-combine-errors"
                tabindex="-1"
                kind={combine_status_kind(assigns)}
                title={@combine_status.title}
              >
                {@combine_status.message}
              </.message>

              <CalendarComponents.combination_controls
                id="calendar-combine-destination"
                form={@combine_form}
                rows={@combine_rows}
                destination_id={@combine_destination_id}
                review={@combine_review}
                version_id={@current_gtfs_version.id}
              />

              <CalendarComponents.combination_decisions
                id="calendar-combine-decisions"
                review={@combine_review}
                rows={@combine_rows}
                decisions={@combine_decisions}
                attempted?={@combine_attempted?}
              />

              <CalendarComponents.combination_result
                id="calendar-combine-result"
                review={@combine_review}
                rows={@combine_rows}
                destination_id={@combine_destination_id}
                stored={@combine_stored}
                today={@today}
                version_id={@current_gtfs_version.id}
              />

              <CalendarComponents.combination_effects
                id="calendar-combine-effects"
                review={@combine_review}
                rows={@combine_rows}
                destination_id={@combine_destination_id}
              />

              <CalendarComponents.combination_impacts
                id="calendar-combine-impacts"
                review={@combine_review}
                rows={@combine_rows}
                destination_id={@combine_destination_id}
                version_id={@current_gtfs_version.id}
              />
            </.drawer_scroll>

            <.drawer_footer>
              <p id="calendar-combine-footer-note" class="mr-auto text-[13px] text-muted">
                {combination_footer_note(assigns)}
              </p>
              <.button
                id="calendar-combine-close"
                type="button"
                phx-click="close_combine"
                disabled={@combine_pending?}
                variant="secondary"
                class="min-h-11"
              >
                {combine_exit_label(assigns)}
              </.button>
              <.button
                :if={@combine_refresh_required?}
                id="calendar-combine-refresh"
                type="button"
                phx-click="combine_refresh"
                disabled={@combine_pending?}
                class="min-h-11 min-w-[196px]"
              >
                <.icon name="hero-arrow-path" class="size-4" /> Refresh review
              </.button>
              <.button
                :if={
                  not @combine_refresh_required? and
                    not CalendarComponents.combination_nothing?(@combine_review)
                }
                id="calendar-combine-apply"
                type="submit"
                disabled={@combine_pending?}
                class="min-h-11 min-w-[196px]"
              >
                {combine_submit_label(assigns)}
              </.button>
            </.drawer_footer>
          </.form>
        </.drawer>

        <.drawer
          id="calendar-coverage-details"
          chrome="planner"
          open={@coverage_detail != nil}
          on_close="close_coverage_details"
          title={coverage_details_title(assigns)}
          return_focus_id={@coverage_return_focus}
          class="max-w-[520px]"
        >
          <CalendarComponents.coverage_details
            :if={@coverage_detail}
            detail={@coverage_detail}
            version_id={@current_gtfs_version.id}
          />
        </.drawer>
      </div>

      <%!--
      The focus events for the panel live on the wrapper above, which survives both the panel
      and the drawer. This hook only moves focus; it never decides focus for the server. --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CalendarHelperFocus">
        export default {
          mounted() {
            this.handleEvent("agent:focus", ({id}) => document.getElementById(id)?.focus())
          }
        }
      </script>

      <%!--
      The extension's transport lifecycle only reports what the browser observes about the
      connection. It never computes a date, never decides that an extension is valid and never
      resends a confirmation: the reviewed command lives on the server and is sent once, by the
      reviewer. --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CalendarExtensionTransport">
        export default {
          disconnected() {
            const notice = this.notice()
            if (!notice) return

            const dispatched = this.el.dataset.extensionDispatched === "true"
            for (const line of notice.querySelectorAll("[data-extension-connection]")) {
              line.hidden = line.dataset.extensionConnection !== (dispatched ? "dispatched" : "idle")
            }
            notice.hidden = false

            const apply = document.getElementById("calendar-extension-apply")
            if (apply) apply.disabled = true
          },

          reconnected() {
            const notice = this.notice()
            if (notice) notice.hidden = true

            const apply = document.getElementById("calendar-extension-apply")
            if (apply) apply.disabled = this.el.dataset.extensionPending === "true"

            this.pushEvent("extension_reconnect", {})
          },

          notice() {
            return this.el.querySelector("#calendar-extension-connection")
          }
        }
      </script>
    </Layouts.app>
    """
  end

  # One semantic table from 1024px up, the same rows as cards below it: a stream renders one
  # structure, so the layout is CSS (`.calendar-table` in `app.css`). The heading holds "Select
  # all" and the two sortable columns, and its second row is the shared date axis; the bar in
  # every row is drawn against the same inner box.
  attr :rows, :any, required: true, doc: "the `:calendars` stream"
  attr :coverage, :map, required: true
  attr :sort_by, :string, required: true
  attr :sort_dir, :string, required: true
  attr :all_selected?, :boolean, required: true
  attr :selected_ids, :any, required: true
  attr :marked_ids, :any, required: true
  attr :version_id, :any, required: true
  attr :scope, :string, required: true

  defp calendars_table(assigns) do
    ~H"""
    <div id="calendars-list-container">
      <table class="calendar-table">
        <caption class="sr-only">
          Calendars in {@scope} and the dates they run
        </caption>
        <thead>
          <tr>
            <th
              scope="col"
              aria-sort={sort_aria(@sort_by, @sort_dir, "name")}
              class="calendar-col-calendar"
            >
              <div class="flex items-center">
                <label class="calendar-check">
                  <input
                    id="calendar-select-all"
                    type="checkbox"
                    checked={@all_selected?}
                    aria-label="Select all matching calendars"
                    phx-click="select_all_calendars"
                  />
                </label>
                <span class="pr-3 text-[13px] font-[650] text-default lg:hidden">Select all</span>
                <button type="button" phx-click="sort" phx-value-key="name" class="calendar-sort">
                  Calendar <.sort_icon state={column_sort_state(@sort_by, @sort_dir, "name")} />
                </button>
              </div>
            </th>
            <th scope="col" aria-sort={sort_aria(@sort_by, @sort_dir, "period")}>
              <div class="lg:px-4">
                <button type="button" phx-click="sort" phx-value-key="period" class="calendar-sort">
                  When it runs <.sort_icon state={column_sort_state(@sort_by, @sort_dir, "period")} />
                </button>
              </div>
            </th>
            <th scope="col" class="calendar-col-trips">Trips</th>
            <th scope="col" class="calendar-col-status">Status</th>
          </tr>
          <tr>
            <td></td>
            <td class="calendar-axis-cell">
              <CalendarComponents.coverage_axis axis={@coverage} />
            </td>
            <td></td>
            <td></td>
          </tr>
        </thead>
        <tbody id="calendars-list" phx-update="stream">
          <tr
            :for={{dom_id, summary} <- @rows}
            id={dom_id}
            data-marked={MapSet.member?(@marked_ids, summary.service_id) || nil}
          >
            <td data-label="Calendar" class="calendar-col-calendar">
              <div class="flex items-start">
                <label :if={is_nil(summary.coverage_error)} class="calendar-check">
                  <input
                    id={"calendar-select-#{URI.encode_www_form(summary.service_id)}"}
                    type="checkbox"
                    checked={MapSet.member?(@selected_ids, summary.service_id)}
                    data-calendar-selected={
                      to_string(MapSet.member?(@selected_ids, summary.service_id))
                    }
                    aria-label={"Select #{summary.name || summary.service_id}"}
                    phx-click="toggle_calendar_selection"
                    phx-value-service-id={summary.service_id}
                  />
                </label>
                <%!-- An identity whose retained range cannot be read has no evaluated dates,
                so it cannot be a combination source: the checkbox stays disabled and the
                repair callout names the fix. --%>
                <label :if={summary.coverage_error} class="calendar-check">
                  <input
                    id={"calendar-select-#{URI.encode_www_form(summary.service_id)}"}
                    type="checkbox"
                    disabled
                    aria-label={"#{summary.name || summary.service_id} cannot be selected because its retained range needs repair."}
                  />
                </label>
                <div class="min-w-0 py-2.5">
                  <.link
                    :if={is_nil(summary.coverage_error)}
                    navigate={detail_path(@version_id, summary)}
                    data-calendar-link={summary.service_id}
                    class="calendar-name"
                  >
                    {summary.name || "Untitled calendar"}
                  </.link>
                  <%!-- An identity whose retained range cannot be read has no date set to
                  inspect or edit, and the detail read evaluates the dates, so its name is
                  plain text here; the repair action is the import link in the dates cell. --%>
                  <span :if={summary.coverage_error} class="font-[650] text-strong">
                    {summary.name || "Untitled calendar"}
                  </span>
                  <div class="mt-0.5 text-[13px] leading-5 text-muted">
                    {CalendarComponents.runs_line(summary)} ·
                    <code class="font-mono">{summary.service_id}</code>
                  </div>
                </div>
              </div>
            </td>
            <td data-label="Service dates" class="calendar-dates-cell">
              <CalendarComponents.coverage_repair
                :if={summary.coverage_error}
                row={summary}
                version_id={@version_id}
              />
              <CalendarComponents.coverage_bar
                :if={is_nil(summary.coverage_error)}
                row={summary}
                coverage={@coverage.rows[summary.service_id]}
                axis={@coverage}
              />
            </td>
            <td
              data-label="Trips"
              data-count={summary.trip_count}
              data-empty={summary.trip_count == 0 || nil}
              class="calendar-col-trips"
            >
              {summary.trip_count}
            </td>
            <td data-label="Status" class="calendar-col-status">
              <% {tone, word} = badge(summary) %>
              <span class={[
                "inline-flex items-center whitespace-nowrap rounded-badge px-2 py-0.5 text-[13px] font-[650]",
                Map.fetch!(badge_tones(), tone)
              ]}>
                {word}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp badge_tones, do: @badge_tones

  defp sort_aria(sort_by, sort_dir, column) do
    case column_sort_state(sort_by, sort_dir, column) do
      "asc" -> "ascending"
      "desc" -> "descending"
      _none -> "none"
    end
  end

  attr :state, :string, required: true

  defp sort_icon(assigns) do
    ~H"""
    <.icon
      name={
        case @state do
          "asc" -> "hero-arrow-up"
          "desc" -> "hero-arrow-down"
          _none -> "hero-chevron-up-down"
        end
      }
      class={["size-3.5", @state == "none" && "text-muted"]}
    />
    """
  end

  defp create_path(assigns) do
    "/gtfs/#{assigns.current_gtfs_version.id}/calendars/new"
  end

  defp detail_path(version_id, summary) do
    "/gtfs/#{version_id}/calendars/show?service_id=" <> URI.encode_www_form(summary.service_id)
  end
end
