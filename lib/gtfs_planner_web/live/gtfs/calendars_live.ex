defmodule GtfsPlannerWeb.Gtfs.CalendarsLive do
  @moduledoc """
  Listing surface for the editable service calendars of one published version.

  The list is a read-only view over the scoped union read model: identities come
  from the weekly, exception and metadata tables through
  `Gtfs.load_calendar_screen/3`, one protected snapshot that also carries the
  agency-local date, the version-wide horizon and gaps, and every row's derived
  periods, exceptions and grouped trip usage. The Service dates column draws each
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

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Calendars.Combination
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.CalendarComponents
  alias GtfsPlannerWeb.Gtfs.CalendarCoverage

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
  @date_change_modes [
    {"One date", "single"},
    {"Date range", "range"},
    {"Several dates", "several"}
  ]
  @date_change_mode_keys Enum.map(@date_change_modes, &elem(&1, 1))
  @sort_keys ~w(name period)
  @sort_dirs ~w(asc desc)
  @range_keys ~w(whole near all)
  @range_options [
    %{value: "whole", label: "Whole feed"},
    %{value: "near", label: "Next 3 months"}
  ]

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
     |> assign_filter_form()
     |> drop_combination()
     |> close_date_change()
     |> stream_configure(:calendars, dom_id: &"calendar-#{URI.encode_www_form(&1.service_id)}")
     |> stream(:calendars, [])}
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
  def handle_event("close_combine", _params, socket), do: {:noreply, drop_combination(socket)}

  @impl true
  def handle_event(
        "combine_destination",
        %{"combine" => %{"destination_id" => destination_id}},
        socket
      )
      when is_binary(destination_id) do
    {:noreply, change_combine_destination(socket, destination_id)}
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

  defp change_combine_destination(socket, destination_id) do
    if Enum.any?(socket.assigns.combine_rows, &(&1.service_id == destination_id)) do
      review_combination(socket, socket.assigns.combine_rows, destination_id)
    else
      socket
    end
  end

  defp review_combination(socket, rows, destination_id) do
    sources =
      rows
      |> Enum.map(& &1.service_id)
      |> Enum.reject(&(&1 == destination_id))
      |> Enum.sort()

    fingerprints = Map.new(rows, &{&1.service_id, &1.fingerprint})

    case Gtfs.review_calendar_change(
           {:combine, destination_id, sources, %{}},
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
        |> assign(:combine_return_focus_id, "calendar-combine-open")

      {:error, reason} ->
        socket
        |> drop_combination()
        |> assign(:combine_error, combine_error_message(reason))
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

  defp drop_combination(socket) do
    socket
    |> assign(:combine_open?, false)
    |> assign(:combine_error, nil)
    |> assign(:combine_destination_id, nil)
    |> assign(:combine_review, nil)
    |> assign(:combine_rows, [])
    |> assign(:combine_stored, nil)
    |> assign(:combine_form, combine_form(nil))
    |> assign(:combine_return_focus_id, nil)
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

  defp combine_error_message(_reason), do: write_error_message(:unavailable)

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
    |> assign(:date_change_open?, false)
    |> assign(:date_change_sources, %{})
    |> assign(:date_change_dates, [])
    |> assign(:date_change_remove, MapSet.new())
    |> assign(:date_change_add, MapSet.new())
    |> assign(:date_change_errors, %{})
    |> assign(:date_change_review, nil)
    |> assign(:date_change_pending?, false)
    |> assign(:date_change_mode, "single")
    |> assign_date_change_form("single", %{})
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
  # Close, and every other review states that nothing has changed until it is combined.
  defp combination_footer_note(review) do
    if CalendarComponents.combination_nothing?(review) do
      "Nothing to combine."
    else
      "Nothing changes until you combine."
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

  defp date_change_label([date]), do: format_date(date)

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

  # Every reviewed line names the calendar, its real trip count and whether the
  # reviewed command actually changes it, so the drawer never implies a write that
  # the atomic command would skip.
  defp date_change_lines(review, sources) do
    changed = MapSet.new(review.affected_service_ids)

    removals = Enum.map(review.remove_from, &target_line("− Stop", &1, sources, changed))
    additions = Enum.map(review.add_to, &target_line("+ Run", &1, sources, changed))

    removals ++ additions
  end

  defp target_line(prefix, service_id, sources, changed) do
    source = Map.fetch!(sources, service_id)
    effect = if MapSet.member?(changed, service_id), do: "changes", else: "already matches"
    "#{prefix} #{source.name} · #{source.trip_count} trips · #{effect}"
  end

  defp warning_text(%{reason: :no_service}), do: "No service would remain on any selected date."

  defp warning_text(%{reason: :ends_soon, last_date: date, days_remaining: days}),
    do: "Service ends #{format_date(date)} · #{days} days away."

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
      <.header>
        Calendars
        <:subtitle>Set the days your trips run, including holidays and breaks.</:subtitle>
      </.header>

      <div :if={@calendars_state in [:ready, :refreshing]} class="mt-4 flex flex-wrap gap-3">
        <button
          :if={not @calendars_empty?}
          id="calendar-date-change"
          type="button"
          phx-click="open_date_change"
          class="btn btn-sm btn-secondary min-h-11"
        >
          Change service on a date
        </button>
        <.link
          id="calendars-create"
          navigate={create_path(assigns)}
          class="btn btn-sm btn-primary min-h-11"
        >
          Create calendar
        </.link>
      </div>

      <p
        :if={@date_change_status}
        id="calendars-date-change-status"
        role="status"
        aria-live="polite"
        class="mt-4 text-sm text-base-content/70"
      >
        {@date_change_status}
      </p>

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
        <CalendarComponents.coverage_invalid
          invalid={@invalid_calendars}
          version_id={@current_gtfs_version.id}
        />

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
            <p :if={@zone && @zone.fallback?} id="calendars-timezone-fallback" role="status">
              Agency timezone {@zone.fallback_reason}; Today and expiry filters use UTC.
            </p>
            <span :if={@today} id="calendars-today" class="text-sm text-base-content/70">
              Today · {format_date(@today)}
            </span>
          </div>

          <div :if={is_list(@gaps) and @gaps != []} id="calendars-feed-gap" class="mt-4">
            <.callout kind="warning" title={"No service on any calendar: #{gap_label(hd(@gaps))}"}>
              This may be intentional. If trips should run, add service for that date.
              <span :if={length(@gaps) > 1} class="block mt-1 text-sm">
                {length(@gaps)} service gaps exist between the first and last active dates.
              </span>
              <button
                id="calendars-feed-gap-review"
                type="button"
                phx-click="open_date_change"
                phx-value-date={Date.to_iso8601(hd(@gaps).first_date)}
                class="btn btn-sm btn-secondary min-h-11 mt-3"
              >
                Review date
              </button>
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
          <div class="grid gap-1.5">
            <span id="calendar-coverage-range-label" class="text-sm font-medium">Timeline</span>
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
            <:action>
              <.link navigate={create_path(assigns)} class="btn btn-sm btn-primary min-h-11">
                Create calendar
              </.link>
            </:action>
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
          :if={
            @coverage != nil and
              ((@range == "whole" and @coverage.clipped?) or (@range == "all" and @long_history?))
          }
          id="calendar-coverage-window"
          class="flex flex-wrap items-center gap-x-2 text-sm text-base-content/70"
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
            class="link link-primary"
          >
            Show all years
          </.link>
          <.link
            :if={@range == "all"}
            id="calendar-coverage-restore"
            patch={range_path(assigns, "whole")}
            class="link link-primary"
          >
            Restore recent range
          </.link>
        </div>

        <div
          :if={@calendars != [] and @calendars_state == :ready}
          id="calendar-selection-bar"
          class={[
            "flex flex-wrap items-center gap-x-4 gap-y-1 rounded-box border border-base-300 px-4 py-1",
            MapSet.size(@selected_service_ids) > 0 && "bg-secondary/5"
          ]}
        >
          <label class="inline-flex min-h-11 cursor-pointer items-center gap-2">
            <input
              id="calendar-select-all"
              type="checkbox"
              class="checkbox checkbox-sm"
              checked={select_all_selected?(assigns)}
              aria-label="Select all matching calendars"
              phx-click="select_all_calendars"
            />
            <span class="text-sm">Select all</span>
          </label>
          <p
            :if={MapSet.size(@selected_service_ids) > 0}
            id="calendar-selection-count"
            role="status"
            class="text-sm font-semibold"
          >
            {selection_count_label(MapSet.size(@selected_service_ids))}
          </p>
          <.button
            :if={MapSet.size(@selected_service_ids) > 0}
            id="calendar-combine-open"
            type="button"
            phx-click="open_combine"
            disabled={MapSet.size(@selected_service_ids) < 2 or @invalid_calendars != []}
            variant="secondary"
            size="sm"
            class="min-h-11"
          >
            Combine calendars
          </.button>
          <p
            :if={MapSet.size(@selected_service_ids) == 0}
            id="calendar-selection-hint"
            class="text-sm text-base-content/70"
          >
            Select two or more calendars to combine them.
          </p>
          <p
            :if={MapSet.size(@selected_service_ids) == 1}
            id="calendar-combine-hint"
            class="text-sm text-base-content/70"
          >
            Select one more calendar to combine.
          </p>
          <p
            :if={@invalid_calendars != []}
            id="calendar-combine-unavailable"
            class="text-sm text-base-content/70"
          >
            Combining is unavailable until the unreadable calendar range is repaired.
          </p>
          <p
            :if={@combine_error}
            id="calendar-combine-error"
            role="alert"
            class="text-sm text-error"
          >
            {@combine_error}
          </p>
          <button
            :if={MapSet.size(@selected_service_ids) > 0}
            id="calendar-clear-selection"
            type="button"
            phx-click="clear_calendar_selection"
            class="btn btn-sm btn-ghost min-h-11 ml-auto"
          >
            Clear selection
          </button>
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
              <div class="flex items-start gap-2">
                <label
                  :if={is_nil(summary.coverage_error)}
                  class="inline-flex min-h-11 min-w-8 cursor-pointer items-center justify-center"
                >
                  <input
                    id={"calendar-select-#{URI.encode_www_form(summary.service_id)}"}
                    type="checkbox"
                    class="checkbox checkbox-sm"
                    checked={MapSet.member?(@selected_service_ids, summary.service_id)}
                    data-calendar-selected={
                      to_string(MapSet.member?(@selected_service_ids, summary.service_id))
                    }
                    aria-label={"Select #{summary.name || summary.service_id}"}
                    phx-click="toggle_calendar_selection"
                    phx-value-service-id={summary.service_id}
                  />
                </label>
                <%!-- An identity whose retained range cannot be read has no evaluated dates,
                so it cannot be a combination source: the checkbox stays disabled and the
                repair callout names the fix. --%>
                <label
                  :if={summary.coverage_error}
                  class="inline-flex min-h-11 min-w-8 items-center justify-center"
                >
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm"
                    disabled
                    aria-label={"#{summary.name || summary.service_id} cannot be selected because its retained range needs repair."}
                  />
                </label>
                <div class="min-w-0">
                  <.link
                    :if={is_nil(summary.coverage_error)}
                    navigate={detail_path(assigns, summary)}
                    data-calendar-link={summary.service_id}
                    class="link link-primary font-semibold"
                  >
                    {summary.name || "Untitled calendar"}
                  </.link>
                  <%!-- An identity whose retained range cannot be read has no date set to
                  inspect or edit, and the detail read evaluates the dates, so its name is
                  plain text here; the repair action is the import link in the Service dates
                  cell. --%>
                  <span :if={summary.coverage_error} class="font-semibold">
                    {summary.name || "Untitled calendar"}
                  </span>
                  <div class="text-sm text-base-content/70">
                    <code class="font-mono">{summary.service_id}</code>
                  </div>
                </div>
              </div>
            </:col>
            <:col :let={{_id, summary}} label="Regular days">
              {CalendarComponents.regular_days(summary)}
            </:col>
            <:col
              :let={{_id, summary}}
              label="Service dates"
              sort_key="period"
              sort_event="sort"
              sort={column_sort_state(@sort_by, @sort_dir, "period")}
              axis={true}
            >
              <CalendarComponents.coverage_repair
                :if={summary.coverage_error}
                row={summary}
                version_id={@current_gtfs_version.id}
              />
              <CalendarComponents.coverage_bar
                :if={is_nil(summary.coverage_error)}
                row={summary}
                coverage={@coverage.rows[summary.service_id]}
                axis={@coverage}
              />
            </:col>
            <:col :let={{_id, summary}} label="Trips" align="right">
              <span class="tabular-nums">{summary.trip_count}</span>
            </:col>
            <:col :let={{_id, summary}} label="Status">
              <% {tone, word} = badge(summary) %>
              <.status_badge status={tone} label={word} />
            </:col>
            <:axis>
              <CalendarComponents.coverage_axis axis={@coverage} />
            </:axis>
          </.table>
          <CalendarComponents.coverage_legend />
        </div>

        <p :if={not @calendars_empty?} class="text-sm text-base-content/70">
          A calendar can be shared by several routes. Changes affect every trip that uses it.
        </p>
      </div>

      <.drawer
        id="calendar-date-change-drawer"
        open={@date_change_open?}
        pending={@date_change_pending?}
        on_close="close_date_change"
        title="Change service on a date"
        initial_focus={:first_field}
        return_focus_id={@date_change_return_focus}
      >
        <.form
          for={@date_change_form}
          id="calendar-date-change-form"
          phx-hook="CalendarDateChange"
          phx-change="date_change_form"
          phx-submit="date_change_add_date"
          class="space-y-6"
        >
          <p class="text-sm text-base-content/70">
            Use a different schedule for a holiday, or stop service for a closure. The reviewed
            command applies to this published version in one transaction.
          </p>

          <p
            :if={@date_change_errors != %{}}
            id="calendar-date-change-error"
            role="alert"
            class="text-sm text-error"
          >
            {Enum.join(Map.values(@date_change_errors), " ")}
          </p>

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
            class="border border-base-300 rounded-box p-4"
          >
            <legend class="font-medium px-1">Stop service on</legend>
            <p class="text-sm text-base-content/70">
              Calendars running on at least one selected date are checked. Choose them yourself and
              this selection stays while the dates change.
            </p>
            <ul class="mt-3 space-y-2">
              <li
                :for={source <- date_change_remove_options(assigns)}
                id={"calendar-date-change-remove-#{URI.encode_www_form(source.service_id)}"}
              >
                <label class="flex items-start gap-3 min-h-11">
                  <input
                    type="checkbox"
                    checked={MapSet.member?(@date_change_remove, source.service_id)}
                    phx-click="date_change_toggle"
                    phx-value-group="remove"
                    phx-value-service-id={source.service_id}
                    aria-label={"Stop service on the selected dates for #{source.name}"}
                  />
                  <span>
                    <span class="font-medium">{source.name}</span>
                    <span class="block text-sm text-base-content/70">
                      <code class="font-mono">{source.service_id}</code> · {source.trip_count} trips
                    </span>
                  </span>
                </label>
              </li>
              <li :if={date_change_remove_options(assigns) == []} class="text-sm text-base-content/70">
                No calendar runs on these dates yet.
              </li>
            </ul>
          </fieldset>

          <fieldset
            :if={@date_change_review == nil}
            id="calendar-date-change-add"
            class="border border-base-300 rounded-box p-4"
          >
            <legend class="font-medium px-1">
              Run instead <span class="font-normal text-base-content/70">(optional)</span>
            </legend>
            <p class="text-sm text-base-content/70">
              Choose every schedule that should run on these dates. A calendar cannot be stopped and
              run at the same time.
            </p>
            <ul class="mt-3 space-y-2">
              <li
                :for={source <- date_change_add_options(assigns)}
                id={"calendar-date-change-add-#{URI.encode_www_form(source.service_id)}"}
              >
                <label class="flex items-start gap-3 min-h-11">
                  <input
                    type="checkbox"
                    checked={MapSet.member?(@date_change_add, source.service_id)}
                    phx-click="date_change_toggle"
                    phx-value-group="add"
                    phx-value-service-id={source.service_id}
                    aria-label={"Run #{source.name} on the selected dates"}
                  />
                  <span>
                    <span class="font-medium">{source.name}</span>
                    <span class="block text-sm text-base-content/70">
                      <code class="font-mono">{source.service_id}</code> · {source.trip_count} trips
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
            class="bg-base-200 rounded-box p-4 text-sm"
          >
            <h3 class="font-semibold">Selection</h3>
            <p id="calendar-date-change-selection">{date_change_label(@date_change_dates)}</p>
            <p class="mt-1 text-base-content/70">Review the result before anything is written.</p>
          </div>

          <div
            :if={@date_change_review != nil}
            id="calendar-date-change-review-panel"
            class="bg-base-200 rounded-box p-4 space-y-3"
          >
            <h3 class="font-semibold">Result after applying</h3>
            <p id="calendar-date-change-review-summary">
              {date_change_label(@date_change_review.selected_dates)}
            </p>
            <ul id="calendar-date-change-review-lines" class="space-y-1 text-sm">
              <li :for={line <- date_change_review_lines(assigns)}>{line}</li>
            </ul>
            <p id="calendar-date-change-review-count" class="text-sm">
              <strong>{@date_change_review.changed_count}</strong>
              rows change across <strong>{length(@date_change_review.affected_service_ids)}</strong>
              {if length(@date_change_review.affected_service_ids) == 1,
                do: "calendar",
                else: "calendars"}.
            </p>
            <div :if={@date_change_review.warnings != []} id="calendar-date-change-warnings">
              <p class="font-medium">
                {length(@date_change_review.warnings)} warnings to read first
              </p>
              <ul class="mt-1 space-y-1 text-sm text-base-content/80">
                <li :for={warning <- @date_change_review.warnings}>{warning_text(warning)}</li>
              </ul>
            </div>
          </div>

          <div class="-mx-6 -mb-6 sticky bottom-0 z-10 flex flex-wrap items-center gap-3 border-t border-base-300 bg-base-100 px-6 pt-3 pb-6">
            <button
              type="button"
              id="calendar-date-change-cancel"
              phx-click="close_date_change"
              class="btn btn-sm btn-ghost min-h-11"
            >
              Cancel
            </button>
            <button
              :if={@date_change_review == nil}
              type="button"
              id="calendar-date-change-review"
              phx-click="date_change_review"
              class="btn btn-sm btn-primary min-h-11"
            >
              Review change
            </button>
            <button
              :if={@date_change_review != nil}
              type="button"
              id="calendar-date-change-back"
              phx-click="date_change_back"
              class="btn btn-sm btn-ghost min-h-11"
            >
              Change selection
            </button>
            <button
              :if={@date_change_review != nil}
              type="button"
              id="calendar-date-change-apply"
              phx-click={JS.dispatch("calendar:apply", to: "#calendar-date-change-form")}
              disabled={@date_change_pending?}
              class="btn btn-sm btn-primary min-h-11"
            >
              {if @date_change_pending?, do: "Applying…", else: "Apply date change"}
            </button>
            <button
              type="button"
              id="calendar-date-change-refresh"
              phx-click="date_change_refresh"
              class="btn btn-sm btn-ghost min-h-11"
            >
              Refresh snapshot
            </button>
          </div>
        </.form>
      </.drawer>

      <.drawer
        id="calendar-combine-drawer"
        open={@combine_open?}
        on_close="close_combine"
        title="Combine calendars"
        return_focus_id={@combine_return_focus_id}
        class="max-w-[min(100vw,760px)]"
      >
        <.form
          :if={@combine_review != nil}
          for={@combine_form}
          id="calendar-combine-form"
          phx-change="combine_destination"
          class="space-y-8"
        >
          <p id="calendar-combine-subtitle" class="text-sm text-base-content/70">
            {selection_count_label(length(@combine_rows))} · {combination_scope(assigns)}
          </p>

          <p
            :if={@combine_error}
            id="calendar-combine-drawer-error"
            role="alert"
            class="text-sm text-error"
          >
            {@combine_error}
          </p>

          <CalendarComponents.combination_controls
            id="calendar-combine-destination"
            form={@combine_form}
            rows={@combine_rows}
            destination_id={@combine_destination_id}
            review={@combine_review}
            version_id={@current_gtfs_version.id}
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

          <CalendarComponents.combination_conflict_labels
            id="calendar-combine-conflicts"
            review={@combine_review}
            rows={@combine_rows}
            today={@today}
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

          <div class="-mx-6 -mb-6 sticky bottom-0 z-10 flex flex-wrap items-center justify-between gap-3 border-t border-base-300 bg-base-100 px-6 pt-3 pb-6">
            <p id="calendar-combine-footer-note" class="text-sm text-base-content/70">
              {combination_footer_note(@combine_review)}
            </p>
            <.button
              id="calendar-combine-close"
              type="button"
              phx-click="close_combine"
              variant="secondary"
              size="sm"
              class="min-h-11"
            >
              Close
            </.button>
          </div>
        </.form>
      </.drawer>

      <.drawer
        id="calendar-coverage-details"
        open={@coverage_detail != nil}
        on_close="close_coverage_details"
        title={coverage_details_title(assigns)}
        return_focus_id={@coverage_return_focus}
        class="max-w-[min(100vw,30rem)]"
      >
        <CalendarComponents.coverage_details
          :if={@coverage_detail}
          detail={@coverage_detail}
          version_id={@current_gtfs_version.id}
        />
      </.drawer>
    </Layouts.app>
    """
  end

  defp create_path(assigns) do
    "/gtfs/#{assigns.current_gtfs_version.id}/calendars/new"
  end

  defp detail_path(assigns, summary) do
    "/gtfs/#{assigns.current_gtfs_version.id}/calendars/show?service_id=" <>
      URI.encode_www_form(summary.service_id)
  end
end
