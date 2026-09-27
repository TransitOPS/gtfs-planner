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
  no identities renders the first-use empty state.

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
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.CalendarComponents

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
     |> assign(:zone, nil)
     |> assign(:today, nil)
     |> assign(:gaps, [])
     |> assign(:calendars_empty?, false)
     |> assign(:filtered_empty?, false)
     |> assign(:constraints?, false)
     |> assign(:search, "")
     |> assign(:status, "all")
     |> assign(:sort_by, "name")
     |> assign(:sort_dir, "asc")
     |> assign(:date_change_status, nil)
     |> assign(:date_change_modes, @date_change_modes)
     |> assign(:date_change_mode, "single")
     |> assign(:date_change_return_focus, "calendar-date-change")
     |> assign_filter_form()
     |> close_date_change()
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
      |> assign(:zone, Map.get(feed_status, :zone))
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
    |> assign(:zone, nil)
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

  defp snapshot_sources(summaries) do
    Map.new(summaries, fn summary ->
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
