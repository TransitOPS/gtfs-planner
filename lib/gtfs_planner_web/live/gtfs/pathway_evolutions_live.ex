defmodule GtfsPlannerWeb.Gtfs.PathwayEvolutionsLive do
  @moduledoc """
  LiveView for a station's scheduled pathway closures.

  This page replaces the Evolutions placeholder. It mounts through the ordinary
  `:gtfs_routes` session and the `:require_gtfs_access` guard, so a member
  without the editor role never reaches it, and it reuses the station
  sub-navigation with `active_tab: :evolutions` — the fifth tab and its stable
  `#station-tab-evolutions` id are unchanged, only the destination behind them
  is real.

  Everything on the page is a scoped read of saved domain state, plus the write
  the editor performs. The list is built from `Gtfs.station_closures/3`, whose
  `:not_found` refusal covers an unknown, foreign, non-station or unpublished
  target: those never reach a render, so no row, count or label can leak from
  another organization, version or stop. The native calendar options come from
  `Gtfs.closure_calendars/2` in the same scope; that read cannot refuse once
  `station_closures/3` has succeeded, because both validate the same scope, so
  its result is matched rather than defaulted to an empty list that would claim
  the version has no calendars.

  Row identity is the closure UUID, and each row's exact `pathway_id` and
  `service_id` travel in text and data attributes, so a natural ID containing a
  slash, percent sign, space or other punctuation round-trips through a link
  without conflation. `?pathway=` filters the visible, clearable search to one
  exact pathway of this station; `?closure=` selects one closure of this station
  by UUID and opens the editor on it. A value outside the scope is ignored rather
  than resolved, so a foreign closure id exposes nothing. `?closure` is applied
  after `?pathway` and clears the filter, because a selected row has to be
  visible to be selected.

  The editor writes through the trusted `Gtfs` mutations only, with the audit
  scope taken from the socket: the organization and version come from the
  mounted session and the page's own station is the `station_stop_id`, so a
  submitted form can never choose its own scope. Create and update keep every
  entered string when the save is rejected — a field error, a duplicate tuple, a
  stale fingerprint, a revoked role — and a stale result keeps the entries until
  the user explicitly reloads the closure. Saving a closure that overlaps another
  window on the same pathway and service says so, as does saving against a
  calendar with no active service dates; neither is a rejection.

  The access preview link is exposed only for a persisted, unchanged closure
  whose calendar and agency zone allow a date to be chosen, and it carries the
  exact `HH:MM:SS` service time. Everything else states why the preview is not
  available instead of offering a link that cannot answer.

  The calendar field carries the calendar's read-only service dates as a
  disclosure. Opening it loads the selected native calendar through
  `Gtfs.get_calendar/3` and renders one month at a time from
  `ServiceDates.month_grid/3`, so the grid, the evaluator and the calendar page
  cannot disagree. Nothing in it writes: the month navigation and the exact link
  to the calendar page are its only controls, and a calendar that has left the
  version is reported while the form keeps every entered value.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.PathwayEvolutionsComponents

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.CalendarComponents
  alias GtfsPlannerWeb.Gtfs.CalendarEditorComponents
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
     |> assign(:editor_mode, nil)
     |> assign(:editor_id, nil)
     |> assign(:editor_fingerprint, nil)
     |> assign(:saved_values, nil)
     |> assign(:form, nil)
     |> assign(:form_errors, [])
     |> assign(:form_submitted?, false)
     |> assign(:duplicate_id, nil)
     |> assign(:stale?, false)
     |> assign(:notices, [])
     |> assign(:dirty?, false)
     |> assign(:pending_action, nil)
     |> assign(:delete_confirm?, false)
     |> assign(:delete_pending?, false)
     |> assign(:preview_href, nil)
     |> assign(:preview_reason, nil)
     |> assign(:dates_open?, false)
     |> assign(:dates_month, nil)
     |> assign(:dates_calendar, nil)
     |> assign(:dates_service_id, nil)
     |> assign(:dates_missing?, false)
     |> assign(:preview, nil)
     |> assign(:preview_status, :idle)
     |> assign(:preview_error, nil)
     |> assign(:preview_generation, 0)
     |> assign(:preview_scope, nil)
     |> assign(:preview_request, nil)
     |> assign(:preview_form, %{date: "", time: ""})
     |> assign(:preview_form_errors, %{})
     |> assign(:preview_zone, nil)
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

        case socket.assigns.live_action do
          :access -> {:noreply, mount_access(socket, params)}
          _list -> {:noreply, render_closures(apply_deep_links(socket, params))}
        end
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
    case find_closure_row(socket, id) do
      nil ->
        {:noreply, socket}

      row ->
        cond do
          # Re-selecting the closure that is already open only puts focus back
          # on the editor it belongs to; it never throws away typed values.
          socket.assigns.editor_id == row.evolution.id ->
            {:noreply, focus_scoped(socket, "closure-editor-title")}

          # Switching rows with unsaved input is an explicit choice, not a
          # silent replacement: the guard keeps the entries and asks.
          socket.assigns.dirty? ->
            {:noreply, assign(socket, :pending_action, {:closure, row.evolution.id})}

          true ->
            {:noreply, select_closure_row(socket, row)}
        end
    end
  end

  def handle_event("select_pathway", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.station_data.pathways, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      pathway ->
        {:noreply, choose_pathway(socket, pathway)}
    end
  end

  def handle_event("start_closure", _params, socket) do
    {:noreply, choose_pathway(socket, nil)}
  end

  def handle_event("validate_closure", %{"closure" => params}, socket) when is_map(params) do
    {:noreply, assign_entered_params(socket, params)}
  end

  # The read-only service dates of the selected calendar. Opening it reads the
  # calendar once through the read contract and starts on the month that matters
  # to the reader; closing it writes nothing and leaves the form untouched.
  def handle_event("toggle_dates", _params, socket) do
    if socket.assigns.dates_open? do
      {:noreply, assign(socket, :dates_open?, false)}
    else
      {:noreply, open_dates(socket)}
    end
  end

  def handle_event("dates_step", %{"step" => step}, socket) when step in ["prev", "next"] do
    offset = if step == "prev", do: -1, else: 1
    {:noreply, assign(socket, :dates_month, shifted_dates_month(socket, offset))}
  end

  def handle_event("dates_step", _params, socket), do: {:noreply, socket}

  # The read-only preview's own keyboard binding: the arrows step one month and
  # Home returns to the agency's month, exactly as the buttons do.
  def handle_event("preview_keys", %{"key" => key}, socket)
      when key in ["ArrowLeft", "ArrowRight", "Home"] do
    {:noreply, assign(socket, :dates_month, dates_key_month(socket, key))}
  end

  def handle_event("preview_keys", _params, socket), do: {:noreply, socket}

  def handle_event("save_closure", %{"closure" => params}, socket) when is_map(params) do
    # The outcome of this attempt replaces whatever the editor said before it,
    # so a selection or creation line never sits beside a rejection.
    socket = assign(socket, :status_message, nil)

    case socket.assigns.editor_mode do
      nil ->
        {:noreply, socket}

      :new ->
        changeset = PathwayEvolution.changeset(%PathwayEvolution{}, params)
        socket = assign(socket, :form_submitted?, true)

        cond do
          not changeset.valid? ->
            {:noreply, show_form_errors(socket, params, changeset)}

          duplicate = duplicate_closure(socket, params) ->
            {:noreply, show_duplicate(socket, params, duplicate)}

          true ->
            {:noreply, submit_create(socket, params)}
        end

      :edit ->
        # The fingerprint compare runs in the context before any field
        # validation, so a row that moved under the editor is reported as stale
        # even when the entered window is also invalid. That precedence is the
        # contract this editor renders against.
        {:noreply, submit_update(assign(socket, :form_submitted?, true), params)}
    end
  end

  def handle_event("reload_closure", _params, socket) do
    socket = reload_station(socket)

    case find_closure_row(socket, socket.assigns.editor_id) do
      nil ->
        {:noreply,
         socket
         |> put_editor(nil)
         |> assign(:status_message, "This closure no longer exists in this service version.")
         |> render_closures()}

      row ->
        {:noreply,
         socket
         |> put_editor(edit_editor(row))
         |> assign(:status_message, "Closure reloaded.")
         |> render_closures()
         |> focus_scoped("closure-editor-title")}
    end
  end

  def handle_event("open_existing_closure", _params, socket) do
    case find_closure_row(socket, socket.assigns.duplicate_id) do
      nil ->
        {:noreply,
         socket
         |> put_editor(nil)
         |> assign(:status_message, "That closure is no longer scheduled at this station.")}

      row ->
        {:noreply, select_closure_row(socket, row)}
    end
  end

  # A link of this app was clicked while the form held unsaved input: the client
  # hook stopped the navigation and pushed the address it was about to open.
  # Only a same-app path is ever kept, so the dialog the guard opens can only
  # ever continue to a page of this application.
  def handle_event("calendar_depart", %{"path" => path}, socket) do
    case same_app_path(path) do
      {:ok, path} ->
        if socket.assigns.dirty? do
          {:noreply, assign(socket, :pending_action, {:link, path})}
        else
          {:noreply, push_navigate(socket, to: path)}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("calendar_depart", _params, socket), do: {:noreply, socket}

  # Keeping the edits leaves every entered string alone and returns focus to the
  # editor the reader was working in.
  def handle_event("keep_editing", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_action, nil)
     |> assign(
       :status_message,
       "Your unsaved changes are still here. Save or discard them before leaving this closure."
     )
     |> focus_scoped("closure-editor-title")}
  end

  # The dialog's own confirmation: the interrupted action runs with the unsaved
  # input dropped.
  def handle_event("discard_edits", _params, socket) do
    case socket.assigns.pending_action do
      nil ->
        {:noreply, socket}

      {:link, path} ->
        {:noreply, push_navigate(assign(socket, :pending_action, nil), to: path)}

      {:closure, id} ->
        case find_closure_row(socket, id) do
          nil ->
            {:noreply,
             socket
             |> assign(:pending_action, nil)
             |> assign(:status_message, "That closure is no longer scheduled at this station.")
             |> focus_scoped("closure-editor-title")}

          row ->
            {:noreply,
             select_closure_row(
               socket,
               row,
               "Closure edits discarded. Selected closure on #{pathway_label(row.pathway)}."
             )}
        end

      {:new, pathway_id} ->
        pathway = Enum.find(socket.assigns.station_data.pathways, &(&1.pathway_id == pathway_id))
        {:noreply, open_new_closure(socket, pathway)}
    end
  end

  # The footer's second action reads "Close" for a clean inspector and "Discard
  # edits" while something is unsaved. An existing row is restored to its
  # persisted values in place; a new form is abandoned, because there is no
  # saved closure to restore it to; a clean inspector closes.
  def handle_event("discard_closure", _params, %{assigns: %{editor_mode: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("discard_closure", _params, %{assigns: %{dirty?: false}} = socket),
    do: {:noreply, close_editor(socket, "Closure closed.")}

  def handle_event("discard_closure", _params, %{assigns: %{editor_mode: :new}} = socket),
    do: {:noreply, close_editor(socket, "New closure discarded.")}

  def handle_event("discard_closure", _params, socket) do
    case find_closure_row(socket, socket.assigns.editor_id) do
      nil ->
        {:noreply, close_editor(socket, "This closure is no longer scheduled at this station.")}

      row ->
        {:noreply,
         select_closure_row(socket, row, "Closure edits discarded. The saved closure is shown.")}
    end
  end

  # The delete confirmation is offered for a persisted row only; opening it is
  # not itself a write. Unlike a row switch, a delete has its own confirmation
  # that names what it removes, so a dirty form does not need a second question
  # first: cancelling this dialog leaves every entered string where it was.
  def handle_event("request_delete", _params, %{assigns: %{editor_mode: :edit}} = socket) do
    {:noreply, assign(socket, :delete_confirm?, true)}
  end

  def handle_event("request_delete", _params, socket), do: {:noreply, socket}

  # Cancelling closes the dialog without touching the row or the form; the
  # shared confirmation returns focus to the button that opened it.
  def handle_event("cancel_delete", _params, %{assigns: %{delete_pending?: false}} = socket) do
    {:noreply, assign(socket, :delete_confirm?, false)}
  end

  def handle_event("cancel_delete", _params, socket), do: {:noreply, socket}

  # The confirmation renders the busy state the shared dialog already owns:
  # both actions are disabled and the confirm action reads "Deleting…" while
  # the context call runs. The call itself is deferred to `handle_info/2`, so
  # the render this handler returns is that busy state and a second
  # confirmation arriving before it completes is refused here.
  def handle_event("confirm_delete", _params, socket) do
    cond do
      socket.assigns.delete_pending? ->
        {:noreply, socket}

      socket.assigns.editor_mode != :edit ->
        {:noreply, socket}

      true ->
        send(self(), :delete_closure)
        {:noreply, assign(socket, :delete_pending?, true)}
    end
  end

  # -- moment access preview -------------------------------------------------

  # The access route's own form: the reader names a service date and time and the
  # page asks the context for that moment. An unparsable pair is a form error and
  # keeps every entered string; it never reaches the context, which takes a Date
  # and integer seconds and would otherwise raise.
  def handle_event("update_preview", %{"preview" => params}, socket) when is_map(params) do
    moment = %{"date" => params["service_date"], "time" => params["service_time"]}

    case moment_params(moment, default_moment_date(socket)) do
      {:ok, date, time} ->
        {:noreply, start_preview(socket, date, time)}

      {:error, form, errors} ->
        {:noreply,
         socket
         |> assign(:preview_form, form)
         |> assign(:preview_form_errors, errors)
         |> assign(:status_message, "Enter a valid service date and time.")}
    end
  end

  def handle_event("update_preview", _params, socket), do: {:noreply, socket}

  # The retry of the last request, not of a new one: the moment is the one the
  # error names, so a repeated failure cannot silently answer a different time.
  def handle_event("retry_preview", _params, socket) do
    case socket.assigns.preview_request do
      %{date: %Date{} = date, time: time} when is_integer(time) ->
        {:noreply, start_preview(socket, date, time)}

      _other ->
        {:noreply, socket}
    end
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

  @impl true
  def handle_info(:delete_closure, socket) do
    socket =
      if socket.assigns.editor_mode == :edit do
        perform_delete(socket)
      else
        close_delete_dialog(socket)
      end

    {:noreply, socket}
  end

  # The preview task returns its own scope, so a completion the reader has
  # already left behind - another moment, another station, another version - is
  # dropped here instead of replacing current output. The task isolates every
  # failure it can observe into its result, so what reaches this clause is the
  # outcome of the request this view started.
  @impl true
  def handle_async(:preview, {:ok, {:preview, scope, result}}, socket) do
    if scope == socket.assigns.preview_scope do
      {:noreply, apply_preview(socket, result)}
    else
      {:noreply, socket}
    end
  end

  # A cancelled task is expected: it was superseded on purpose and must never be
  # presented as a failure.
  def handle_async(:preview, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  # Only the current task's exit reaches this clause, because a superseded task's
  # reference is no longer the one this view waits on. The retained result, if
  # there is one, stays visible under its stale label.
  def handle_async(:preview, {:exit, _reason}, socket) do
    if socket.assigns.preview_status == :loading do
      {:noreply, preview_failed(socket, :unexpected)}
    else
      {:noreply, socket}
    end
  end

  # The station is kept across a version change only because the mount resolves
  # it again in the new scope. A version that does not hold the station reaches
  # the missing-station response, which flashes and returns to that version's
  # stops list rather than rendering an empty station under its name. The access
  # route keeps its service moment, and its own mount clears the result the old
  # version produced.
  defp version_target(socket, version_id) do
    case socket.assigns.stop_id do
      stop_id when is_binary(stop_id) ->
        case socket.assigns.live_action do
          :access -> access_target(version_id, stop_id, socket.assigns.preview_request)
          _list -> ~p"/gtfs/#{version_id}/stops/#{stop_id}/evolutions"
        end

      _absent ->
        ~p"/gtfs/#{version_id}/stops"
    end
  end

  defp access_target(version_id, stop_id, %{date: %Date{} = date, time: time})
       when is_integer(time) do
    query =
      URI.encode_query([
        {"date", Date.to_iso8601(date)},
        {"time", GtfsTime.format(time)}
      ])

    "/gtfs/#{version_id}/stops/#{URI.encode(stop_id)}/evolutions/access?#{query}"
  end

  defp access_target(version_id, stop_id, _moment),
    do: "/gtfs/#{version_id}/stops/#{URI.encode(stop_id)}/evolutions/access"

  # -- access preview: mounted state -----------------------------------------

  # Twelve o'clock on the service date, which is what the page previews until the
  # reader names another moment or arrives through a `?date`/`?time` link.
  @preview_default_time 43_200

  # The access route's mounted state: one service moment, its result, and the
  # agency zone both depend on. The default moment is the agency's own today, so
  # the page opens on the day the reader is in without asking.
  defp mount_access(socket, params) do
    clock =
      DisplayClock.today(
        socket.assigns.current_organization.id,
        socket.assigns.current_gtfs_version.id
      )

    # A result belongs to the station and version that produced it, so a patch
    # that keeps both (another moment of the same station) retains it under the
    # stale label, while a different station or version starts clean.
    socket = if same_place?(socket), do: socket, else: assign(socket, :preview, nil)

    socket =
      socket
      |> cancel_async(:preview)
      |> assign(:preview_status, :idle)
      |> assign(:preview_error, nil)
      |> assign(:preview_scope, nil)
      |> assign(:preview_request, nil)
      |> assign(:preview_form, %{date: "", time: ""})
      |> assign(:preview_form_errors, %{})
      |> assign(:preview_zone, clock)
      |> assign(:status_message, nil)
      # A request from the route this one replaced keeps its generation, so any
      # completion still in flight can never match the state this route mounts.
      |> assign(:preview_generation, socket.assigns.preview_generation + 1)

    # Time-aware evaluation never uses the display clock's UTC fallback, so an
    # unusable agency zone replaces the calculation instead of naming an instant
    # in the wrong zone. Closure authoring stays reachable through the switch.
    if clock.fallback? do
      socket
    else
      case moment_params(%{"date" => params["date"], "time" => params["time"]}, clock.date) do
        {:ok, date, time} -> start_preview(socket, date, time)
        {:error, form, errors} -> assign(socket, preview_form: form, preview_form_errors: errors)
      end
    end
  end

  defp same_place?(socket) do
    case socket.assigns.preview_scope do
      {_organization_id, version_id, stop_id, _generation} ->
        version_id == socket.assigns.current_gtfs_version.id and stop_id == socket.assigns.stop_id

      _absent ->
        false
    end
  end

  defp default_moment_date(socket) do
    case socket.assigns.preview_zone do
      %{date: %Date{} = date} -> date
      _zone -> Date.utc_today()
    end
  end

  # A service date and a service time from either the route or the form. Both
  # arrive as strings, both are optional, and a value that does not parse is
  # reported as a form error rather than passed to the context, which assumes a
  # parsed date and integer seconds.
  defp moment_params(params, default_date) do
    date = parse_moment_date(params["date"], default_date)
    time = parse_moment_time(params["time"])

    errors =
      [date: date, time: time]
      |> Enum.flat_map(fn {field, result} ->
        case result do
          {:ok, _value} -> []
          {:error, message} -> [{field, message}]
        end
      end)
      |> Map.new()

    form = %{
      date: entered(params["date"], default_date),
      time: entered(params["time"], @preview_default_time)
    }

    case {date, time} do
      {{:ok, date}, {:ok, time}} -> {:ok, date, time}
      _invalid -> {:error, form, errors}
    end
  end

  defp entered(value, _default) when is_binary(value), do: value
  defp entered(_value, %Date{} = default), do: Date.to_iso8601(default)
  defp entered(_value, seconds) when is_integer(seconds), do: GtfsTime.format(seconds)

  defp parse_moment_date(nil, default), do: {:ok, default}
  defp parse_moment_date("", default), do: {:ok, default}

  defp parse_moment_date(value, _default) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "Enter a service date like 2026-10-06."}
    end
  end

  defp parse_moment_date(_value, default), do: {:ok, default}

  defp parse_moment_time(nil), do: {:ok, @preview_default_time}
  defp parse_moment_time(""), do: {:ok, @preview_default_time}

  defp parse_moment_time(value) when is_binary(value) do
    case PathwayEvolution.parse_service_time(value) do
      {:ok, seconds} -> {:ok, seconds}
      {:error, :invalid_time} -> {:error, "Enter a service time like 09:00 or 25:30."}
    end
  end

  defp parse_moment_time(_value), do: {:ok, @preview_default_time}

  # One request per moment. The generation and the mounted scope travel with the
  # request into the task and come back with its result, so a completion can be
  # matched against what this view is waiting for. The retained result is never
  # cleared here: the stale label is what tells the reader it is the earlier one.
  defp start_preview(socket, %Date{} = date, time) when is_integer(time) do
    generation = socket.assigns.preview_generation + 1

    scope =
      {socket.assigns.current_organization.id, socket.assigns.current_gtfs_version.id,
       socket.assigns.stop_id, generation}

    socket
    |> assign(:preview_generation, generation)
    |> assign(:preview_scope, scope)
    |> assign(:preview_request, %{date: date, time: time})
    |> assign(:preview_status, :loading)
    |> assign(:preview_error, nil)
    |> assign(:preview_form, %{date: Date.to_iso8601(date), time: GtfsTime.format(time)})
    |> assign(:preview_form_errors, %{})
    |> assign(:status_message, "Checking access at #{moment_label(date, time)}…")
    |> cancel_async(:preview)
    |> start_async(:preview, fn -> load_preview(scope, date, time) end)
  end

  # Runs in the task process with ids and parsed values only. Every failure it can
  # observe is captured here, so an unhandled raise never arrives as an unscoped
  # exit that could be attributed to a request this view did not make.
  defp load_preview({organization_id, gtfs_version_id, stop_id, _generation} = scope, date, time) do
    {:preview, scope,
     Gtfs.preview_closures(organization_id, gtfs_version_id, stop_id, date, time)}
  rescue
    exception -> {:preview, scope, {:error, {:unexpected, exception}}}
  catch
    kind, reason -> {:preview, scope, {:error, {:unexpected, {kind, reason}}}}
  end

  defp apply_preview(socket, {:ok, preview}) do
    socket
    |> assign(:preview, preview)
    |> assign(:preview_status, :ready)
    |> assign(:preview_error, nil)
    |> assign(:status_message, preview_announcement(socket, preview))
  end

  # The agency zone became unusable after the page resolved it: the context owns
  # that refusal, and the page names it instead of showing a result for the wrong
  # zone. Authoring stays reachable through the switch.
  defp apply_preview(socket, {:error, {:timezone_unavailable, reason}}) do
    socket
    |> assign(:preview, nil)
    |> assign(:preview_status, :idle)
    |> assign(:preview_error, nil)
    |> assign(:preview_zone, %{timezone: "UTC", fallback?: true, fallback_reason: reason})
    |> assign(:status_message, "Access cannot be checked: the agency time zone is unavailable.")
  end

  defp apply_preview(socket, {:error, :not_found}) do
    socket
    |> put_flash(:error, "Station not found")
    |> push_navigate(to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/stops")
  end

  defp apply_preview(socket, {:error, :analysis_too_large}),
    do: preview_failed(socket, :too_large)

  defp apply_preview(socket, {:error, _reason}), do: preview_failed(socket, :unexpected)

  defp preview_failed(socket, reason) do
    socket
    |> assign(:preview_status, :failed)
    |> assign(:preview_error, reason)
    |> assign(:status_message, "The access check stopped before it finished.")
  end

  defp preview_announcement(socket, preview) do
    headings =
      case preview_banner_copy(socket.assigns.station_data, preview) do
        nil -> "Access check incomplete."
        %{title: title} -> title <> "."
      end

    "Access at #{moment_label(preview.service_date, preview.service_time)}: #{headings}"
  end

  # -- access preview: presentation ------------------------------------------

  defp moment_label(%Date{} = date, time), do: "#{service_clock(time)} on #{long_date(date)}"

  defp long_date(%Date{} = date), do: Calendar.strftime(date, "%A, %B %-d, %Y")

  defp short_date(%Date{} = date), do: Calendar.strftime(date, "%b %-d")

  defp service_clock(seconds) when is_integer(seconds), do: service_time_value(seconds)

  # A UTC offset in seconds as `+HH:MM`, which is what the moment line shows
  # beside the local clock time.
  defp offset_label(seconds) when is_integer(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    total = abs(seconds)
    hours = div(total, 3600) |> Integer.to_string() |> String.pad_leading(2, "0")
    minutes = div(rem(total, 3600), 60) |> Integer.to_string() |> String.pad_leading(2, "0")
    sign <> hours <> ":" <> minutes
  end

  defp preview_moment_label(assigns) do
    with %{local_time: %NaiveDateTime{} = local, instant: %DateTime{} = instant} <-
           assigns.preview,
         %{fallback?: false} <- assigns.preview_zone do
      offset = NaiveDateTime.diff(local, DateTime.to_naive(instant), :second)

      elsewhere =
        if NaiveDateTime.to_date(local) == assigns.preview.service_date,
          do: "",
          else: " #{short_date(NaiveDateTime.to_date(local))}"

      "#{long_date(assigns.preview.service_date)} · " <>
        "#{service_clock(assigns.preview.service_time)} service time " <>
        "(#{DisplayClock.format_time(local)}#{elsewhere} UTC#{offset_label(offset)})"
    else
      _absent -> nil
    end
  end

  defp preview_computed_label(assigns) do
    with %{computed_at: %DateTime{} = computed_at} <- assigns.preview,
         %{fallback?: false} = zone <- assigns.preview_zone do
      [local] = DisplayClock.localize_many([computed_at], zone)
      "Calculated #{DisplayClock.format_time(local)}"
    else
      _absent -> nil
    end
  end

  # The stale label is attached to the retained result, never to the new request:
  # it names what is on screen and what is still being calculated, or that the
  # check of the requested moment stopped before it finished.
  defp preview_stale_detail(assigns) do
    case {assigns.preview, assigns.preview_request} do
      {%{} = preview, %{date: %Date{} = date, time: time}} ->
        shown = short_moment(preview.service_date, preview.service_time)
        requested = short_moment(date, time)

        cond do
          assigns.preview_status == :loading ->
            "· showing #{shown} while #{requested} is calculated"

          assigns.preview_error != nil ->
            "· showing #{shown}; the check at #{requested} stopped before it finished"

          true ->
            nil
        end

      _other ->
        nil
    end
  end

  defp preview_short_moment(assigns) do
    case assigns.preview do
      %{service_date: %Date{} = date, service_time: time} -> short_moment(date, time)
      _absent -> nil
    end
  end

  defp short_moment(%Date{} = date, time),
    do: "#{service_clock(time)} on #{Calendar.strftime(date, "%a, %b %-d")}"

  defp preview_error_detail(%{preview_error: :too_large}) do
    "That date and time need too many service dates to check. Choose a moment within the version's calendar range."
  end

  defp preview_error_detail(_assigns) do
    "Nothing was changed. Check again; if it stops again, reload the page."
  end

  defp preview_zone_note(%{preview_zone: %{fallback?: false, timezone: timezone}}) do
    "#{timezone} · 24-hour time. 25:00 means 1 AM on the next day of this service."
  end

  defp preview_zone_note(_assigns), do: nil

  # Why the analysis is off, in the reader's terms. Closure authoring is never
  # blocked by an unusable zone, so the switch and the settings link stay.
  defp timezone_copy(%{preview_zone: %{fallback?: true, fallback_reason: reason}}) do
    case reason do
      :missing ->
        %{
          heading: "Access can’t be checked: this version has no agency time zone",
          reason:
            "No agency in this version has a time zone. Service times count from one agency time zone, so moment previews stay off until it is set.",
          fix: "set the agency time zone in Settings › Agencies."
        }

      :invalid ->
        %{
          heading: "Access can’t be checked: the agency time zone is not recognized",
          reason:
            "The agency time zone is not a name PostgreSQL recognizes, so no service-day instant can be resolved from it.",
          fix: "correct it in Settings › Agencies."
        }

      :conflicting ->
        %{
          heading: "Access can’t be checked: the agencies use different time zones",
          reason:
            "This version’s agencies disagree about the time zone. Service times count from one agency time zone, so moment previews stay off until they match.",
          fix: "set the same time zone for every agency in Settings › Agencies."
        }

      _other ->
        %{
          heading: "Access can’t be checked: the agency time zone is unavailable",
          reason:
            "The agency time zone could not be resolved, so no service-day instant can be named.",
          fix: "check the agency time zone in Settings › Agencies."
        }
    end
  end

  defp timezone_copy(_assigns), do: nil

  # The active closures of one moment, prepared for display: the pathway and its
  # exact ID, the calendar and window, and the spill note when the instance
  # originates on an earlier service day than the one being previewed.
  defp preview_causes(assigns) do
    case assigns.preview do
      %{closed: [_ | _] = instances} -> Enum.map(instances, &preview_cause(&1, assigns))
      _absent -> []
    end
  end

  defp preview_cause(instance, assigns) do
    row = closure_row(assigns.station_data.closures, instance.evolution_id)
    {calendar_label, _detail} = calendar_lines(row && row.calendar, instance.service_id)

    %{
      id: instance.evolution_id,
      pathway_label: if(row, do: pathway_label(row.pathway), else: instance.pathway_id),
      pathway_id: instance.pathway_id,
      detail:
        [calendar_label, window_label(instance), spill_note(instance, assigns)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · "),
      href: closures_view_path(assigns) <> "?closure=" <> instance.evolution_id
    }
  end

  defp spill_note(instance, assigns) do
    if Date.compare(instance.service_date, assigns.preview.service_date) == :eq do
      nil
    else
      "from the #{long_date(instance.service_date)} service day · until #{local_end_label(instance.ends_at, assigns.preview_zone)}"
    end
  end

  defp local_end_label(%DateTime{} = instant, %{fallback?: false} = zone) do
    [local] = DisplayClock.localize_many([instant], zone)
    "#{DisplayClock.format_time(local)} #{short_date(NaiveDateTime.to_date(local))}"
  end

  defp local_end_label(_instant, _zone), do: nil

  # The banner is the answer of the moment: the step-free consequence when a
  # platform lost its last step-free route, otherwise how many connections were
  # lost, otherwise an explicit all-clear. An incomplete evaluation has no
  # banner at all - its own region says why the check cannot answer.
  defp preview_banner_copy(_snapshot, nil), do: nil

  defp preview_banner_copy(snapshot, preview) do
    if incomplete_preview?(preview) do
      nil
    else
      comparison = preview.comparison

      case step_free_heading(comparison, snapshot) || loss_heading(comparison) do
        nil ->
          %{tone: :ok, title: "No connection lost at this time", body: all_clear_body(preview)}

        heading ->
          %{tone: :loss, title: heading, body: loss_body(preview, comparison, snapshot)}
      end
    end
  end

  defp incomplete_preview?(preview),
    do: preview.base.status == :incomplete or preview.effective.status == :incomplete

  defp step_free_heading(comparison, snapshot) do
    to = comparison.platforms_without_step_free.to_platform
    from = comparison.platforms_without_step_free.to_exit

    both = Enum.filter(to, &(&1 in from))
    to_only = Enum.reject(to, &(&1 in from))
    from_only = Enum.reject(from, &(&1 in to))

    parts =
      [
        both != [] && "to or from " <> platform_names(both, snapshot),
        to_only != [] && "to " <> platform_names(to_only, snapshot),
        from_only != [] && "from " <> platform_names(from_only, snapshot)
      ]
      |> Enum.reject(&(&1 == false))

    case parts do
      [] -> nil
      parts -> "No step-free route " <> Enum.join(parts, ", or ")
    end
  end

  defp loss_heading(comparison) do
    case comparison.lost do
      [] -> nil
      lost -> "#{length(lost)} entrance–platform connections lost"
    end
  end

  defp all_clear_body(%{closed: []}),
    do: "No closure is active. Every entrance keeps its walking and step-free connections."

  defp all_clear_body(_preview),
    do: "The active closure removes no entrance–platform connection."

  # The contributing closures, what still works, and the pairs the base graph
  # never connected: three separate statements, so no closure is claimed to be
  # the single cause of a loss and no baseline gap is blamed on a closure.
  defp loss_body(preview, comparison, snapshot) do
    [
      Enum.map_join(preview.closed, " ", &cause_sentence(&1, preview.service_date, snapshot)),
      walking_remaining(preview, comparison, snapshot),
      baseline_gap_sentences(comparison, snapshot)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp cause_sentence(instance, service_date, snapshot) do
    row = closure_row(snapshot.closures, instance.evolution_id)

    mode = if row, do: Pathway.mode_label(row.pathway.pathway_mode), else: "Pathway"
    ends = if row, do: ends_label(row.pathway), else: instance.pathway_id

    spill =
      if Date.compare(instance.service_date, service_date) == :eq,
        do: "",
        else: " from the #{long_date(instance.service_date)} service day"

    "#{mode} #{instance.pathway_id} (#{ends}) is closed #{window_label(instance)}#{spill}."
  end

  defp walking_remaining(preview, comparison, snapshot) do
    affected =
      comparison.platforms_without_step_free.to_platform
      |> Kernel.++(comparison.platforms_without_step_free.to_exit)
      |> Enum.uniq()

    kept =
      Enum.filter(affected, fn platform_id ->
        preview.effective.pairs
        |> Enum.filter(&(&1.platform_id == platform_id))
        |> Enum.any?(&(&1.walking_to_platform or &1.walking_to_exit))
      end)

    case kept do
      [] -> ""
      kept -> "Walking connections to and from #{platform_names(kept, snapshot)} remain."
    end
  end

  defp baseline_gap_sentences(comparison, snapshot) do
    comparison.baseline_gaps
    |> Enum.filter(&(&1.mode == :step_free))
    |> Enum.uniq_by(&{&1.entrance_id, &1.platform_id})
    |> Enum.map_join(" ", fn gap ->
      "#{child_stop_name(snapshot, gap.entrance_id)} has no step-free route to " <>
        "#{child_stop_name(snapshot, gap.platform_id)} even without closures."
    end)
  end

  defp preview_incomplete_reasons(assigns) do
    case assigns.preview do
      %{} = preview ->
        if incomplete_preview?(preview) do
          (preview.base.incomplete_reasons ++ preview.effective.incomplete_reasons)
          |> Enum.uniq()
          |> Enum.map(&incomplete_reason(&1, assigns.station_data))
        end

      _absent ->
        nil
    end
  end

  defp incomplete_reason(:no_entrances, _snapshot),
    do: "This station has no entrance (location_type 2) to start from."

  defp incomplete_reason(:no_platforms, _snapshot),
    do: "This station has no platform (location_type 0) to reach."

  defp incomplete_reason({:cross_station_pathways, [pathway_id]}, _snapshot) do
    "Pathway #{pathway_id} connects to a stop outside this station, so it is " <>
      "evaluated but its result is not part of this station's pairs."
  end

  defp incomplete_reason({:cross_station_pathways, pathway_ids}, _snapshot) do
    "Pathways #{Enum.join(pathway_ids, ", ")} connect to a stop outside this " <>
      "station, so they are evaluated but not part of this station's pairs."
  end

  defp incomplete_reason(_reason, _snapshot), do: "Part of this station's data is missing."

  defp closure_row(closures, evolution_id),
    do: Enum.find(closures, &(&1.evolution.id == evolution_id))

  defp child_stop_name(snapshot, stop_id) do
    case Enum.find(snapshot.child_stops, &(&1.stop_id == stop_id)) do
      %{stop_name: name} when is_binary(name) and name != "" -> name
      _stop -> stop_id
    end
  end

  defp platform_names(platform_ids, snapshot),
    do: Enum.map_join(platform_ids, " and ", &child_stop_name(snapshot, &1))

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
    case find_closure_row(socket, closure_id) do
      nil ->
        socket

      row ->
        # A deep link opens the editor on the row it names, but does not move
        # focus: the reader asked for the page, not for the form.
        socket
        |> put_editor(edit_editor(row))
        |> assign(:selected_closure_id, row.evolution.id)
        |> assign(:search, "")
        |> assign(:status_message, "Selected closure on #{pathway_label(row.pathway)}.")
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

  # A closure row is addressed by its own UUID inside this station's snapshot;
  # looking it up here is what keeps a deep link, a duplicate link and a save
  # from ever reaching a row outside the mounted scope.
  defp find_closure_row(socket, id) when is_binary(id) do
    Enum.find(socket.assigns.station_data.closures, &(to_string(&1.evolution.id) == id))
  end

  defp find_closure_row(_socket, _id), do: nil

  # -- editor ----------------------------------------------------------------

  # Choosing a pathway opens the new-closure form on it, or re-points the one
  # already open. Switching away from typed values is never silent: while any
  # unsaved input exists the form is kept and the guard asks first.
  defp choose_pathway(socket, pathway) do
    cond do
      socket.assigns.editor_mode == :new ->
        values = Map.put(socket.assigns.form.params, "pathway_id", pathway_id(pathway))

        socket
        |> assign_entered_params(values)
        |> assign(:selected_pathway_id, pathway && pathway.id)
        |> assign(:status_message, "Choose a calendar and a window for this closure.")
        |> focus_scoped("closure-calendar")

      socket.assigns.dirty? ->
        assign(socket, :pending_action, {:new, pathway && pathway.id})

      true ->
        open_new_closure(socket, pathway)
    end
  end

  # The new-closure form, used when nothing unsaved has to be kept: the pathway
  # list, the header's action, and the dirty dialog's own confirmation.
  defp open_new_closure(socket, pathway) do
    socket
    |> put_editor(new_editor(pathway_id(pathway)))
    |> assign(:selected_pathway_id, pathway && pathway.id)
    |> assign(:selected_closure_id, nil)
    |> assign(:search, "")
    |> assign(:status_message, "Scheduling a new closure.")
    |> render_closures()
    |> focus_new_closure(pathway)
  end

  # Opening a row: the editor, the selected row styling and the announcement
  # travel together, so a switch, a duplicate link, a reload and a discarded
  # draft all land on the same shape.
  defp select_closure_row(socket, row, message \\ nil) do
    socket
    |> put_editor(edit_editor(row))
    |> assign(:selected_closure_id, row.evolution.id)
    |> assign(:status_message, message || "Selected closure on #{pathway_label(row.pathway)}.")
    |> refresh_rows()
    |> focus_scoped("closure-editor-title")
  end

  defp close_editor(socket, message) do
    socket
    |> put_editor(nil)
    |> assign(:selected_closure_id, nil)
    |> assign(:selected_pathway_id, nil)
    |> assign(:status_message, message)
    |> refresh_rows()
    |> focus_scoped("closure-idle-title")
  end

  # -- delete ----------------------------------------------------------------

  # What the delete confirmation names: the selected row's pathway, calendar
  # and window, derived from the same labels the list and the editor use. It is
  # nil unless a persisted closure is open, so the dialog can only describe a
  # row of this station's snapshot. The saved row is what a delete removes, so
  # unsaved edits in the form are deliberately not part of it.
  defp delete_target(%{editor_mode: :edit, editor_id: id} = assigns) when is_binary(id) do
    case Enum.find(assigns.station_data.closures, &(to_string(&1.evolution.id) == id)) do
      nil ->
        nil

      closure ->
        {calendar_label, _detail} =
          calendar_lines(closure.calendar, closure.evolution.service_id)

        %{
          pathway_label: pathway_full_label(closure.pathway),
          pathway_id: closure.evolution.pathway_id,
          calendar_label: calendar_label,
          window: window_label(closure.evolution),
          window_note: window_note(closure.evolution)
        }
    end
  end

  defp delete_target(_assigns), do: nil

  # The row is addressed by the UUID and the fingerprint the editor holds, so a
  # delete based on a row that moved under it is refused as stale and removes
  # nothing. The confirmation's own target is read before the call, so the
  # success message can still name the calendar the deleted row kept.
  defp perform_delete(socket) do
    target = delete_target(socket.assigns)

    case Gtfs.delete_pathway_evolution(
           socket.assigns.editor_id,
           socket.assigns.editor_fingerprint,
           audit_context(socket)
         ) do
      {:ok, _result} -> deleted_closure(socket, target)
      {:error, reason} -> refused_delete(socket, reason)
    end
  end

  # A committed delete is re-read rather than patched: the list loses the row,
  # the editor returns to its idle state and the outcome is announced. Focus
  # lands on the re-streamed list; when the last match went with the row the
  # list is replaced by its own empty state, so the next useful target is that
  # state's Create closure action.
  defp deleted_closure(socket, target) do
    socket =
      socket
      |> reload_station()
      |> put_editor(nil)
      |> assign(:selected_closure_id, nil)
      |> assign(:selected_pathway_id, nil)
      |> assign(:status_message, deleted_message(target))
      |> render_closures()

    focus_scoped(
      socket,
      if(socket.assigns.match_count > 0, do: "closures-list", else: "new-closure")
    )
  end

  defp deleted_message(%{calendar_label: label}), do: "Closure deleted. #{label} is unchanged."
  defp deleted_message(_target), do: "Closure deleted."

  # A refused delete never removes anything and never drops the form: a stale
  # fingerprint shows the same reload path a stale save does, a revoked role
  # and a row that is already gone keep their values and say so.
  defp refused_delete(socket, :stale_review) do
    socket
    |> close_delete_dialog()
    |> assign(:form_errors, [])
    |> assign(:duplicate_id, nil)
    |> assign(:notices, [])
    |> assign(:stale?, true)
    |> assign(
      :status_message,
      "Delete refused: this closure changed after you opened it. Reload it and try again."
    )
    |> focus_scoped("closure-stale")
  end

  defp refused_delete(socket, :forbidden) do
    socket
    |> close_delete_dialog()
    |> assign(:status_message, "Delete refused: you no longer have permission to edit closures.")
    |> put_flash(:error, "You no longer have permission to edit closures.")
  end

  defp refused_delete(socket, :not_found) do
    socket
    |> close_delete_dialog()
    |> assign(
      :status_message,
      "Delete refused: this closure is no longer in this service version."
    )
    |> put_flash(:error, "This closure is no longer available in this service version.")
  end

  defp refused_delete(socket, _reason) do
    socket
    |> close_delete_dialog()
    |> assign(:status_message, "The closure was not deleted. Nothing was written; try again.")
  end

  defp close_delete_dialog(socket) do
    socket
    |> assign(:delete_confirm?, false)
    |> assign(:delete_pending?, false)
  end

  # With a pathway already chosen the calendar is the next field to fill in;
  # without one, the pathway picker is.
  defp focus_new_closure(socket, nil), do: focus_scoped(socket, "closure-pathway")
  defp focus_new_closure(socket, _pathway), do: focus_scoped(socket, "closure-calendar")

  defp pathway_id(nil), do: ""
  defp pathway_id(pathway), do: pathway.pathway_id

  # The editor's two shapes: a new closure and an existing row carrying the
  # fingerprint a save must present. A new closure's saved baseline is the
  # pathway it was opened on, so opening a form from the pathway list is not
  # itself an unsaved change.
  defp new_editor(pathway_id) do
    values = new_values(pathway_id)

    %{mode: :new, id: nil, fingerprint: nil, saved: values, values: values}
  end

  defp edit_editor(row) do
    values = saved_values(row.evolution)

    %{
      mode: :edit,
      id: row.evolution.id,
      fingerprint: row.fingerprint,
      saved: values,
      values: values
    }
  end

  defp new_values(pathway_id) do
    %{
      "pathway_id" => pathway_id || "",
      "service_id" => "",
      "start_time" => "",
      "end_time" => "",
      "note" => ""
    }
  end

  defp saved_values(%PathwayEvolution{} = evolution) do
    %{
      "pathway_id" => evolution.pathway_id || "",
      "service_id" => evolution.service_id || "",
      "start_time" => format_service_time(evolution.start_time),
      "end_time" => format_service_time(evolution.end_time),
      "note" => evolution.note || ""
    }
  end

  defp format_service_time(seconds) when is_integer(seconds), do: service_time_value(seconds)
  defp format_service_time(_seconds), do: ""

  # Opening the idle editor, a new form or an existing row resets every outcome
  # from the previous one, so a stale flag, a duplicate panel, a notice or a
  # pending guarded action can never outlive the row it described.
  defp put_editor(socket, editor) do
    {preview_href, preview_reason} = preview_state(socket, editor)

    socket
    |> assign(:pending_action, nil)
    |> assign(:delete_confirm?, false)
    |> assign(:delete_pending?, false)
    |> assign(:editor_mode, editor && editor.mode)
    |> assign(:editor_id, editor && editor.id)
    |> assign(:editor_fingerprint, editor && editor.fingerprint)
    |> assign(:saved_values, editor && editor.saved)
    |> assign(:form, editor && closure_form(editor.values))
    |> assign(:form_errors, [])
    |> assign(:form_submitted?, false)
    |> assign(:duplicate_id, nil)
    |> assign(:stale?, false)
    |> assign(:notices, [])
    |> assign(:dirty?, editor != nil and dirty?(editor.values, editor.saved))
    |> assign(:preview_href, preview_href)
    |> assign(:preview_reason, preview_reason)
    |> reset_dates()
  end

  # A form change keeps every entered string and re-checks the fields only once
  # the user has already been told about a problem, so a half-filled form never
  # shouts "can't be blank" at someone still typing. Duplicate and notice
  # outcomes belong to the submitted tuple and are dropped by any edit.
  defp assign_entered_params(socket, params) do
    changeset = PathwayEvolution.changeset(%PathwayEvolution{}, params)
    errors = if socket.assigns.form_submitted?, do: changeset.errors, else: []

    socket
    |> assign(:form, closure_form(params, errors))
    |> assign(
      :form_errors,
      if(socket.assigns.form_submitted?, do: field_errors(changeset), else: [])
    )
    |> assign(:dirty?, dirty?(params, socket.assigns.saved_values))
    |> assign(:duplicate_id, nil)
    |> assign(:notices, [])
    |> sync_dates()
  end

  # -- read-only service dates ------------------------------------------------

  # Opening the disclosure reads the selected calendar once through the same
  # contract the calendar page uses. Nothing here writes: a calendar that has
  # gone from the version is reported, and the form keeps every entered value.
  defp open_dates(socket) do
    case selected_service_id(socket) do
      nil -> assign(socket, :dates_open?, false)
      service_id -> socket |> assign(:dates_open?, true) |> load_dates(service_id)
    end
  end

  defp load_dates(socket, service_id) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_calendar(organization_id, gtfs_version_id, service_id) do
      {:ok, calendar} ->
        socket
        |> assign(:dates_service_id, service_id)
        |> assign(:dates_calendar, calendar)
        |> assign(:dates_missing?, false)
        |> assign(:dates_month, initial_dates_month(calendar))

      {:error, :not_found} ->
        socket
        |> assign(:dates_service_id, service_id)
        |> assign(:dates_calendar, nil)
        |> assign(:dates_missing?, true)
        |> assign(:dates_month, nil)
    end
  end

  # A newly opened editor starts with the dates closed and forgotten, so no
  # loaded calendar can describe a different row's selection.
  defp reset_dates(socket) do
    socket
    |> assign(:dates_open?, false)
    |> forget_dates()
  end

  defp forget_dates(socket) do
    socket
    |> assign(:dates_service_id, nil)
    |> assign(:dates_calendar, nil)
    |> assign(:dates_missing?, false)
    |> assign(:dates_month, nil)
  end

  # The dates describe the selected calendar. A selection that changes while the
  # disclosure is open is loaded once; while it is closed nothing is read until
  # the reader asks to see it; clearing the calendar puts the disclosure away,
  # because there is no calendar whose service days could be shown.
  defp sync_dates(socket) do
    case selected_service_id(socket) do
      nil ->
        reset_dates(socket)

      service_id ->
        cond do
          socket.assigns.dates_service_id == service_id -> socket
          socket.assigns.dates_open? -> load_dates(socket, service_id)
          true -> forget_dates(socket)
        end
    end
  end

  # The month the disclosure opens on: the calendar's earliest active date on or
  # after the agency's today, its earliest active date when it has ended, and the
  # agency's own month when it has none. That is the same date rule the access
  # preview uses to name an instant.
  defp initial_dates_month(calendar) do
    calendar
    |> preview_date()
    |> Kernel.||(calendar.today)
    |> first_of_month()
  end

  defp first_of_month(%Date{year: year, month: month}), do: Date.new!(year, month, 1)

  defp shifted_dates_month(%{assigns: %{dates_month: nil}}, _offset), do: nil

  defp shifted_dates_month(socket, offset),
    do: CalendarComponents.shift_month(socket.assigns.dates_month, offset)

  defp dates_key_month(socket, "Home") do
    case socket.assigns.dates_calendar do
      %{today: %Date{} = today} -> first_of_month(today)
      _other -> nil
    end
  end

  defp dates_key_month(socket, "ArrowLeft"), do: shifted_dates_month(socket, -1)
  defp dates_key_month(socket, "ArrowRight"), do: shifted_dates_month(socket, 1)

  # The form's own selection: the calendar the editor is working on, or nil while
  # no calendar is chosen. The value keeps the exact stored `service_id`.
  defp selected_service_id(%{assigns: %{form: %{params: params}}}) when is_map(params) do
    case params["service_id"] do
      service_id when is_binary(service_id) and service_id != "" -> service_id
      _other -> nil
    end
  end

  defp selected_service_id(_socket), do: nil

  defp show_form_errors(socket, params, %Ecto.Changeset{} = changeset) do
    socket
    |> assign(:form, closure_form(params, changeset.errors))
    |> assign(:form_errors, field_errors(changeset))
    |> assign(:dirty?, dirty?(params, socket.assigns.saved_values))
    |> assign(:duplicate_id, nil)
    |> assign(:notices, [])
    |> push_event("focus_form_error", %{form_id: "closure-form", fallback_id: "closure-errors"})
  end

  defp field_errors(changeset) do
    Enum.map(changeset.errors, fn {field, {message, opts}} ->
      %{id: field_id(field), message: error_message(field, message, opts)}
    end)
  end

  # A field message is the changeset's own sentence, which reads on its own
  # under the field; in the summary list it needs the field it belongs to. A
  # base error already names its subject and stays as it is.
  defp error_message(field, message, opts) do
    case closure_field_label(field) do
      nil -> translate_error({message, opts})
      label -> "#{label}: #{translate_error({message, opts})}"
    end
  end

  defp closure_field_label(:pathway_id), do: "Pathway"
  defp closure_field_label(:service_id), do: "Calendar"
  defp closure_field_label(:start_time), do: "Starts at"
  defp closure_field_label(:end_time), do: "Ends at"
  defp closure_field_label(:note), do: "Note"
  defp closure_field_label(_base), do: nil

  # The stable ids of the editor's controls, so an error summary entry can focus
  # the field it names. A base error has no field and stays plain text.
  defp field_id(:pathway_id), do: "closure-pathway"
  defp field_id(:service_id), do: "closure-calendar"
  defp field_id(:start_time), do: "closure-start"
  defp field_id(:end_time), do: "closure-end"
  defp field_id(:note), do: "closure-note"
  defp field_id(_base), do: nil

  # The form renders the entered parameters verbatim: the changeset normalizes
  # service times to seconds inside its own params, so rendering from the
  # changeset would show "32400" where the reader typed "09:00". The changeset
  # still owns the messages, which are attached to the parameters-only form.
  defp closure_form(params, errors \\ []) do
    to_form(params, as: :closure, errors: errors)
  end

  # Entered values are compared after the same normalization the changeset
  # applies, so 9:00, 09:00 and 09:00:00 are one value and a trailing space in a
  # note is not an edit.
  defp dirty?(params, saved) do
    comparable_values(params) != comparable_values(saved)
  end

  # The client's guard compares the rendered form to the values this page last
  # rendered as saved — the same tuple the server-side check compares, keyed by
  # the field names the browser submits. That is what lets a click swallowed in
  # the same moment as a field's blur still be refused. It is omitted while no
  # editor is open, which leaves other users of the hook untouched.
  defp dirty_baseline(nil), do: nil

  defp dirty_baseline(values) do
    Jason.encode!(Map.new(values, fn {key, value} -> {"closure[#{key}]", value} end))
  end

  # What the dialog says it would drop: a new closure that was never saved, or
  # the changes to the closure that is open.
  defp dirty_dialog_body(%{editor_mode: :new}),
    do: "This new closure is not saved. Discarding removes it."

  defp dirty_dialog_body(assigns) do
    case editor_pathway(assigns) do
      nil ->
        "Your changes are not saved. Discarding restores the saved closure."

      pathway ->
        "Your changes to #{pathway_full_label(pathway)} are not saved. " <>
          "Discarding restores the saved closure."
    end
  end

  # A departure address is accepted only as a same-app absolute path: it starts
  # with one slash, and it carries neither a scheme nor a host. An absolute URL,
  # a protocol-relative address and a script URL are all refused, so a path the
  # guard kept can never become navigation to another origin.
  defp same_app_path(path) when is_binary(path) do
    uri = URI.parse(path)

    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
         is_nil(uri.scheme) and is_nil(uri.host) do
      {:ok, path}
    else
      :error
    end
  end

  defp same_app_path(_path), do: :error

  defp comparable_values(nil), do: comparable_values(%{})

  defp comparable_values(params) do
    %{
      pathway_id: to_string(params["pathway_id"] || ""),
      service_id: to_string(params["service_id"] || ""),
      start_time: comparable_time(params["start_time"]),
      end_time: comparable_time(params["end_time"]),
      note: String.trim(to_string(params["note"] || ""))
    }
  end

  defp comparable_time(value) do
    case PathwayEvolution.parse_service_time(value) do
      {:ok, seconds} -> seconds
      {:error, :invalid_time} -> String.trim(to_string(value || ""))
    end
  end

  # The saved tuple is looked up in the rows this station already has, so the
  # duplicate panel can only ever point at a closure of the mounted scope.
  defp duplicate_closure(socket, params) do
    tuple = {
      params["pathway_id"],
      params["service_id"],
      comparable_time(params["start_time"]),
      comparable_time(params["end_time"])
    }

    Enum.find(socket.assigns.station_data.closures, fn row ->
      row.evolution.id != socket.assigns.editor_id and
        {row.evolution.pathway_id, row.evolution.service_id, row.evolution.start_time,
         row.evolution.end_time} == tuple
    end)
  end

  defp submit_create(socket, params) do
    case Gtfs.create_pathway_evolution(params, audit_context(socket)) do
      {:ok, result} ->
        applied_closure(socket, result)

      {:error, %Ecto.Changeset{} = changeset} ->
        rejected_changeset(socket, params, changeset)

      {:error, reason} ->
        rejected_save(socket, reason)
    end
  end

  defp submit_update(socket, params) do
    submitted_fingerprint = socket.assigns.editor_fingerprint

    case Gtfs.update_pathway_evolution(
           socket.assigns.editor_id,
           params,
           submitted_fingerprint,
           audit_context(socket)
         ) do
      {:ok, result} ->
        applied_closure(socket, result, unchanged?: result.fingerprint == submitted_fingerprint)

      {:error, :stale_review} ->
        rejected_save(socket, params, :stale_review)

      {:error, %Ecto.Changeset{} = changeset} ->
        rejected_changeset(socket, params, changeset)

      {:error, reason} ->
        rejected_save(socket, reason)
    end
  end

  # A rejected tuple that matches a row this station already has is a duplicate
  # with a scoped way out; any other rejection renders its field errors.
  defp rejected_changeset(socket, params, changeset) do
    case duplicate_closure(socket, params) do
      nil -> show_form_errors(socket, params, changeset)
      duplicate -> show_duplicate(socket, params, duplicate)
    end
  end

  defp show_duplicate(socket, params, duplicate) do
    socket
    |> assign_entered_params(params)
    |> assign(:duplicate_id, duplicate.evolution.id)
    |> focus_scoped("closure-errors")
  end

  # A committed write is re-read rather than patched from the mutation result:
  # the list, the row and the editor then all describe the row the database now
  # holds, including a no-op save that wrote nothing.
  defp applied_closure(socket, result, opts \\ []) do
    socket = reload_station(socket)

    case find_closure_row(socket, result.evolution.id) do
      nil ->
        socket
        |> assign(:status_message, "Closure saved.")
        |> render_closures()

      row ->
        socket
        |> put_editor(edit_editor(row))
        |> assign(:notices, notice_views(result.notices, row))
        |> assign(
          :status_message,
          if(Keyword.get(opts, :unchanged?, false),
            do: "No changes to save.",
            else: "Closure saved."
          )
        )
        |> assign(:selected_closure_id, row.evolution.id)
        |> render_closures()
    end
  end

  # A stale fingerprint keeps every entered string and disables the save until
  # the user has seen the current row; nothing is written either way.
  defp rejected_save(socket, params, :stale_review) do
    socket
    |> assign(:form, closure_form(params))
    |> assign(:form_errors, [])
    |> assign(:dirty?, dirty?(params, socket.assigns.saved_values))
    |> assign(:duplicate_id, nil)
    |> assign(:notices, [])
    |> assign(:stale?, true)
    |> focus_scoped("closure-stale")
  end

  defp rejected_save(socket, %Ecto.Changeset{} = changeset) do
    show_form_errors(socket, changeset.params || %{}, changeset)
  end

  defp rejected_save(socket, :forbidden) do
    put_flash(socket, :error, "You no longer have permission to edit closures.")
  end

  defp rejected_save(socket, :not_found) do
    put_flash(socket, :error, "This closure is no longer available in this service version.")
  end

  defp notice_views(notices, row) do
    Enum.map(notices, fn
      {:overlaps, others} -> overlap_notice(row.pathway, others, row.calendar)
      :no_active_dates -> no_active_dates_notice(row.calendar)
    end)
  end

  defp reload_station(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.station_closures(organization_id, gtfs_version_id, socket.assigns.stop_id) do
      {:ok, station_data} -> assign(socket, :station_data, station_data)
      {:error, :not_found} -> socket
    end
  end

  # The editor's context line and copy follow whichever pathway the form holds;
  # the lookup stays inside this station's snapshot.
  defp editor_pathway(assigns) do
    with %{params: params} when is_map(params) <- assigns.form,
         pathway_id when is_binary(pathway_id) <- params["pathway_id"],
         pathway when not is_nil(pathway) <-
           Enum.find(assigns.station_data.pathways, &(&1.pathway_id == pathway_id)) do
      pathway
    else
      _other -> nil
    end
  end

  defp editor_calendar(assigns) do
    with %{params: params} when is_map(params) <- assigns.form,
         service_id when is_binary(service_id) <- params["service_id"],
         option when not is_nil(option) <-
           Enum.find(assigns.calendars, &(&1.service_id == service_id)) do
      option
    else
      _other -> nil
    end
  end

  # The preview link exists for one case only: a persisted closure whose
  # calendar, agency zone and active dates let a single exact instant be named.
  # Everything else carries the reason instead.
  defp preview_state(_socket, nil), do: {nil, nil}
  defp preview_state(_socket, %{mode: :new}), do: {nil, nil}

  defp preview_state(socket, %{mode: :edit, saved: saved}) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.get_calendar(organization_id, gtfs_version_id, saved["service_id"]) do
      {:ok, %{zone: %{fallback?: false}} = calendar} ->
        case preview_date(calendar) do
          nil ->
            {nil,
             "#{calendar.label} has no active service dates, so there is nothing to preview."}

          date ->
            {access_path(socket.assigns, date, saved["start_time"]), nil}
        end

      {:ok, %{zone: %{fallback_reason: reason}}} ->
        {nil,
         "The agency time zone is unavailable (#{zone_reason(reason)}), so a preview " <>
           "date cannot be chosen. Closure authoring still works."}

      {:error, :not_found} ->
        {nil, "This closure's calendar is no longer in this service version."}
    end
  end

  # The earliest active date on or after the agency's today, or the earliest
  # active date when the calendar has already ended; nil when it has none.
  defp preview_date(%{active_dates: [], today: _today}), do: nil

  defp preview_date(%{active_dates: dates, today: today}) do
    Enum.find(dates, &(Date.compare(&1, today) != :lt)) || List.first(dates)
  end

  defp zone_reason(:missing), do: "no agency in this version has one"
  defp zone_reason(:invalid), do: "the agency time zone is not recognized"
  defp zone_reason(:conflicting), do: "this version's agencies disagree"
  defp zone_reason(_reason), do: "it could not be resolved"

  # The access view itself lands in a later step; this step's link is the exact
  # address it will answer, with the service time as HH:MM:SS and the station
  # and query encoded exactly as the router decodes them.
  # The access route with an exact service moment. `comparable_time/1` accepts
  # both the stored integer seconds and the `H:MM` the form shows, so a closure
  # row's `HH:MM:SS` link and the view's own moment build one address. Both this
  # and the two helpers below read the mounted assigns, which the render pass and
  # the socket both carry.
  defp access_path(assigns, date, start_time) do
    query =
      URI.encode_query([
        {"date", Date.to_iso8601(date)},
        {"time", GtfsTime.format(comparable_time(start_time))}
      ])

    "#{evolutions_view_path(assigns)}/access?#{query}"
  end

  # The address of the other Evolutions view, for the view switch and for a
  # cause link back to the closure that caused a loss.
  defp closures_view_path(assigns), do: evolutions_view_path(assigns)

  # The switch's own access link carries the moment currently requested, so a
  # reader who leaves and returns finds the same service date and time instead of
  # the default noon, and the link is never a different request than the page.
  defp access_view_path(%{preview_request: %{date: %Date{} = date, time: time}} = assigns)
       when is_integer(time) do
    access_path(assigns, date, time)
  end

  defp access_view_path(assigns), do: evolutions_view_path(assigns) <> "/access"

  defp evolutions_view_path(assigns) do
    version_id = assigns.current_gtfs_version.id
    "/gtfs/#{version_id}/stops/#{URI.encode(assigns.stop_id)}/evolutions"
  end

  defp audit_context(socket) do
    %AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      station_stop_id: socket.assigns.stop_id,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end

  # The scoped focus hook only focuses an element the editor already owns.
  defp focus_scoped(socket, id), do: push_event(socket, "focus_scoped_target", %{id: id})

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
    assigns =
      assigns
      |> assign(:editor_pathway, editor_pathway(assigns))
      |> assign(:editor_calendar, editor_calendar(assigns))
      |> assign(:preview_unavailable, preview_unavailable(assigns))
      |> assign(
        :preview_href,
        if(preview_unavailable(assigns), do: nil, else: assigns.preview_href)
      )
      |> assign(:dirty_baseline, dirty_baseline(assigns.saved_values))
      |> assign(:dirty_dialog_body, dirty_dialog_body(assigns))
      |> assign(:delete_target, delete_target(assigns))
      |> assign(:calendar_href, calendar_href(assigns))
      |> assign(:dates_month_grid, dates_month_grid(assigns))
      |> assign(:dates_month_label, dates_month_label(assigns))
      |> assign(:dates_prev_label, dates_step_label(assigns, -1))
      |> assign(:dates_next_label, dates_step_label(assigns, 1))
      |> assign(:dates_no_active?, dates_no_active?(assigns))
      |> assign(:closures_view_href, closures_view_path(assigns))
      |> assign(:access_view_href, access_view_path(assigns))
      |> assign(:preview_causes, preview_causes(assigns))
      |> assign(:preview_banner, preview_banner_copy(assigns.station_data, assigns.preview))
      |> assign(:preview_computed_label, preview_computed_label(assigns))
      |> assign(:preview_moment_label, preview_moment_label(assigns))
      |> assign(:preview_short_moment, preview_short_moment(assigns))
      |> assign(:preview_stale_detail, preview_stale_detail(assigns))
      |> assign(:preview_incomplete_reasons, preview_incomplete_reasons(assigns))
      |> assign(:preview_error_detail, preview_error_detail(assigns))
      |> assign(:preview_zone_note, preview_zone_note(assigns))
      |> assign(:timezone_copy, timezone_copy(assigns))
      |> assign(:preview_lost?, assigns.preview != nil and assigns.preview.comparison.lost != [])
      |> assign(
        :preview_skeleton?,
        assigns.preview_status == :loading and assigns.preview == nil
      )

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
        <.evolutions_view_nav
          current={@live_action}
          closures_href={@closures_view_href}
          access_href={@access_view_href}
        />

        <%= if @live_action == :access do %>
          <%!--
          The access view: one service moment, its comparison against the same
          station without closures, and the active closures that contributed.
          Outcomes are announced in the polite status region below; the visible
          regions carry the same text.
          --%>
          <p
            id="evolutions-status"
            role="status"
            aria-live="polite"
            class="sr-only"
          >
            {@status_message}
          </p>

          <%!--
          Time-aware evaluation never uses the display clock's UTC fallback, so
          an unusable agency zone replaces the analysis rather than naming an
          instant in the wrong zone. Authoring stays reachable through the view
          switch and the settings link.
          --%>
          <section
            :if={@timezone_copy}
            id="analysis-timezone-unavailable"
            aria-labelledby="tz-title"
            class="mt-4 flex max-w-3xl gap-3 rounded-card bg-warning/10 px-5 py-4 text-base-content"
          >
            <.icon name="hero-clock" class="mt-0.5 size-5 shrink-0 text-warning" />
            <div class="min-w-0">
              <h2 id="tz-title" class="font-display text-[20px] text-warning">
                {@timezone_copy.heading}
              </h2>
              <p id="tz-reason" class="mt-2 text-sm">{@timezone_copy.reason}</p>
              <p class="mt-2 text-sm">
                <strong class="font-[650] text-strong">To fix:</strong> {@timezone_copy.fix}
              </p>
              <p class="mt-2 text-sm">You can still create and edit closures.</p>
              <div class="mt-3 flex flex-wrap gap-x-5">
                <a
                  id="tz-settings"
                  href={"/gtfs/#{@current_gtfs_version.id}/settings/agencies"}
                  class="inline-flex min-h-11 items-center text-sm font-[650] text-action hover:underline"
                >
                  Open agency settings
                </a>
                <.link
                  id="tz-closures"
                  patch={@closures_view_href}
                  class="inline-flex min-h-11 items-center text-sm font-[650] text-action hover:underline"
                >
                  Schedule closures
                </.link>
              </div>
            </div>
          </section>

          <div :if={is_nil(@timezone_copy)} id="access-analysis">
            <form
              id="preview-form"
              phx-submit="update_preview"
              novalidate
              class="mt-4 rounded-card border border-subtle bg-white px-4 py-3 md:px-5"
            >
              <div class="flex flex-wrap items-end gap-x-3 gap-y-2">
                <div class="grid gap-1.5">
                  <label for="preview-date" class="text-[13px] font-[650] text-base-content">
                    Service date
                  </label>
                  <input
                    id="preview-date"
                    name="preview[service_date]"
                    type="date"
                    value={@preview_form.date}
                    required
                    aria-describedby="preview-zone preview-date-error"
                    aria-invalid={@preview_form_errors[:date] && "true"}
                    class="h-11 w-[10.5rem] rounded-control border border-control bg-white px-3 text-sm tabular-nums text-strong aria-[invalid=true]:border-2 aria-[invalid=true]:border-error"
                  />
                </div>
                <div class="grid gap-1.5">
                  <label for="preview-time" class="text-[13px] font-[650] text-base-content">
                    Service time
                  </label>
                  <input
                    id="preview-time"
                    name="preview[service_time]"
                    type="text"
                    inputmode="numeric"
                    autocomplete="off"
                    spellcheck="false"
                    value={@preview_form.time}
                    aria-describedby="preview-zone preview-time-error"
                    aria-invalid={@preview_form_errors[:time] && "true"}
                    class="h-11 w-28 rounded-control border border-control bg-white px-3 font-mono text-sm tabular-nums text-strong aria-[invalid=true]:border-2 aria-[invalid=true]:border-error"
                  />
                </div>
                <.button
                  id="update-preview"
                  type="submit"
                  phx-disable-with="Updating…"
                  class="h-11 min-w-[136px] rounded-control bg-action px-4 text-sm font-[650] text-white hover:bg-evo-action-hover"
                >
                  Update preview
                </.button>
                <p
                  id="preview-zone"
                  class="flex min-h-11 max-w-[42rem] items-center text-[13px] leading-snug text-muted md:ml-2"
                >
                  {@preview_zone_note}
                </p>
              </div>
              <p
                :if={@preview_form_errors[:date]}
                id="preview-date-error"
                role="alert"
                class="mt-2 flex items-center gap-1.5 text-[13px] font-[650] text-error"
              >
                <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
                {@preview_form_errors[:date]}
              </p>
              <p
                :if={@preview_form_errors[:time]}
                id="preview-time-error"
                role="alert"
                class="mt-2 flex items-center gap-1.5 text-[13px] font-[650] text-error"
              >
                <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
                {@preview_form_errors[:time]}
              </p>
            </form>

            <div id="preview-area" class="mt-4 grid grid-cols-[minmax(0,1fr)] gap-4">
              <p
                :if={@preview_stale_detail}
                id="analysis-stale"
                class="flex flex-wrap items-center gap-x-2 gap-y-1 rounded-control bg-warning/10 px-4 py-2.5 text-[13px] text-warning"
              >
                <.icon name="hero-clock" class="size-4 shrink-0" />
                <strong class="font-[650]">Results are from an earlier check</strong>
                <span id="analysis-stale-detail">{@preview_stale_detail}</span>
              </p>

              <.preview_banner
                :if={@preview_banner}
                id="preview-result"
                title={@preview_banner.title}
                body={@preview_banner.body}
                tone={@preview_banner.tone}
                computed_label={@preview_computed_label}
                moment_label={@preview_moment_label}
              />

              <%!--
              An incomplete evaluation is never an all-clear: it says what the
              check cannot answer, keeps the known pairs below, and leaves the
              decision to fix the station data.
              --%>
              <section
                :if={@preview_incomplete_reasons}
                id="analysis-incomplete"
                aria-labelledby="incomplete-title"
                class="flex gap-3 rounded-card bg-warning/10 px-5 py-4 text-base-content"
              >
                <.icon
                  name="hero-exclamation-triangle"
                  class="mt-0.5 size-5 shrink-0 text-warning"
                />
                <div class="min-w-0 flex-1">
                  <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
                    <h2 id="incomplete-title" class="font-display text-[20px] text-warning">
                      Access check incomplete
                    </h2>
                    <p id="incomplete-computed" class="text-[13px] tabular-nums text-warning">
                      {@preview_computed_label}
                    </p>
                  </div>
                  <p class="mt-1.5 text-sm">
                    This check can’t say whether any connection is lost until the station data is fixed:
                  </p>
                  <ul id="incomplete-reasons" class="mt-1 list-disc pl-5 text-sm">
                    <li :for={reason <- @preview_incomplete_reasons}>{reason}</li>
                  </ul>
                  <p id="incomplete-moment" class="mt-1.5 text-[13px] tabular-nums text-muted">
                    {@preview_moment_label}
                  </p>
                  <a
                    id="incomplete-floorplans"
                    href={"/gtfs/#{@current_gtfs_version.id}/stops/#{URI.encode(@stop_id)}/diagram"}
                    class="mt-1 inline-flex min-h-11 items-center text-sm font-[650] text-action hover:underline"
                  >
                    Review pathways on Floorplans
                  </a>
                </div>
              </section>

              <section
                :if={@preview_error}
                id="analysis-error"
                aria-labelledby="error-title"
                class="flex gap-3 rounded-card bg-error/10 px-5 py-4 text-base-content"
              >
                <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-error" />
                <div class="min-w-0">
                  <h2 id="error-title" class="font-display text-[20px] text-error">
                    The access check stopped before it finished
                  </h2>
                  <p id="analysis-error-detail" class="mt-1.5 text-sm">
                    {@preview_error_detail}
                  </p>
                  <button
                    id="analysis-retry"
                    type="button"
                    phx-click="retry_preview"
                    class="mt-3 inline-flex min-h-11 items-center justify-center gap-2 rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas"
                  >
                    <.icon name="hero-arrow-path" class="size-4" /> Check again
                  </button>
                </div>
              </section>

              <%!--
              The first load: a skeleton in the shape of the answer, with no
              numbers in it. The status region above announces the same state
              for a reader who cannot see it.
              --%>
              <section
                :if={@preview_skeleton?}
                id="preview-skeleton"
                aria-hidden="true"
                class="grid grid-cols-[minmax(0,1fr)] gap-4"
              >
                <div class="rounded-card border border-subtle bg-white px-5 py-4">
                  <p class="font-display text-[18px] text-strong">Checking access…</p>
                  <div class="mt-3 h-3.5 w-72 max-w-full rounded-evo-badge bg-canvas motion-safe:animate-pulse">
                  </div>
                  <div class="mt-2 h-3.5 w-96 max-w-full rounded-evo-badge bg-canvas motion-safe:animate-pulse">
                  </div>
                </div>
              </section>

              <.preview_findings
                :if={@preview}
                snapshot={@station_data}
                preview={@preview}
                causes={@preview_causes}
                moment={@preview_short_moment}
                incomplete?={not is_nil(@preview_incomplete_reasons)}
                lost?={@preview_lost?}
              />
            </div>
          </div>
        <% end %>

        <div
          :if={@live_action != :access}
          id="closures-workspace"
          class={[
            "grid items-start gap-6",
            is_nil(@blocked) && "lg:grid-cols-[minmax(0,1fr)_440px] lg:grid-rows-[auto_1fr]"
          ]}
        >
          <%!--
          The list region owns its own scoped focus hook, so the confirmed
          delete can land focus on the re-streamed `#closures-list` (or on the
          empty state's Create action when the last match went with the row).
          The editor keeps its own `CalendarEditor` instance.
          --%>
          <section
            id="closures-card"
            phx-hook="FormErrorFocus"
            aria-labelledby="closures-title"
            class="min-w-0 rounded-card border border-subtle bg-white lg:col-start-1 lg:row-start-1"
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

          <%!--
          The editor stays non-modal beside the list: it is a form for the row the
          list selected, and on the access step it is the surface a preview link
          returns to.
          --%>
          <aside
            :if={is_nil(@blocked)}
            id="closure-editor"
            phx-hook="CalendarEditor"
            data-dirty={to_string(@dirty?)}
            data-dirty-baseline={@dirty_baseline}
            data-closure-id={@editor_id}
            aria-labelledby={if @editor_mode, do: "closure-editor-title", else: "closure-idle-title"}
            class="flex min-w-0 flex-col overflow-clip rounded-card border border-subtle bg-white lg:sticky lg:top-4 lg:col-start-2 lg:row-span-2 lg:row-start-1 lg:max-h-[calc(100dvh-2rem)]"
          >
            <p
              id="evolutions-status"
              role="status"
              aria-live="polite"
              class={[
                "items-center gap-2 border-b border-subtle px-5 py-2.5 text-sm",
                @status_message && "text-strong",
                !@status_message && "hidden"
              ]}
            >
              {@status_message}
            </p>

            <div :if={is_nil(@editor_mode)} id="closure-idle" class="px-5 py-5">
              <h2
                id="closure-idle-title"
                tabindex="-1"
                class="font-sans text-[18px] font-[650] leading-snug tracking-normal"
              >
                No closure selected
              </h2>
              <p id="closure-idle-guidance" class="mt-1.5 text-sm text-default">
                Choose a closure to edit it, or choose a pathway to schedule a new one.
              </p>
              <p class="mt-4 border-t border-subtle pt-4 text-[13px] text-muted">
                Saving updates this version immediately. Full exports include closures.
              </p>
            </div>

            <.form
              :if={@editor_mode}
              for={@form}
              id="closure-form"
              novalidate
              phx-change="validate_closure"
              phx-submit="save_closure"
              class="flex min-h-0 flex-1 flex-col"
            >
              <header class="border-b border-subtle px-5 py-4">
                <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
                  <h2
                    id="closure-editor-title"
                    tabindex="-1"
                    class="font-sans text-[20px] font-[650] leading-tight tracking-normal"
                  >
                    {if @editor_mode == :new, do: "New closure", else: "Edit closure"}
                  </h2>
                  <span
                    :if={@dirty?}
                    id="closure-dirty-chip"
                    class="inline-flex items-center gap-1.5 rounded-evo-badge bg-warning/15 px-2 py-0.5 text-[13px] font-[650] text-warning"
                  >
                    <.icon name="hero-exclamation-triangle" class="size-3.5" /> Unsaved changes
                  </span>
                </div>
                <p id="closure-editor-context" class="mt-1 text-[13px] text-muted">
                  <span :if={@editor_pathway}>
                    {pathway_full_label(@editor_pathway)} ·
                    <span class="font-mono text-[12px]">{@editor_pathway.pathway_id}</span>
                  </span>
                  <span :if={is_nil(@editor_pathway)}>
                    {station_name(@station)} · {@current_gtfs_version.name}
                  </span>
                </p>
              </header>

              <div
                id="closure-body"
                class="grid content-start gap-5 px-5 py-5 lg:min-h-0 lg:flex-1 lg:overflow-y-auto"
              >
                <.callout
                  :if={@duplicate_id || @form_errors != []}
                  id="closure-errors"
                  kind="error"
                  title={
                    if @duplicate_id, do: "This closure already exists.", else: "Closure not saved"
                  }
                  tabindex="-1"
                >
                  <ul :if={is_nil(@duplicate_id)} id="closure-errors-list" class="grid gap-0.5">
                    <li :for={error <- @form_errors}>
                      <button
                        :if={error.id}
                        type="button"
                        phx-click={JS.focus(to: "#" <> error.id)}
                        class="inline-flex min-h-11 items-center text-left text-error underline underline-offset-4"
                      >
                        {error.message}
                      </button>
                      <span :if={is_nil(error.id)} class="text-error">{error.message}</span>
                    </li>
                  </ul>
                  <div :if={@duplicate_id}>
                    <p id="closure-duplicate" class="text-sm">
                      Another closure has the same pathway, calendar and window.
                    </p>
                    <button
                      id="closure-open-existing"
                      type="button"
                      phx-click="open_existing_closure"
                      class="-mb-2 inline-flex min-h-11 items-center gap-1.5 text-sm font-[650] text-error underline underline-offset-4"
                    >
                      Open existing closure
                    </button>
                  </div>
                </.callout>

                <.callout
                  :if={@stale?}
                  id="closure-stale"
                  kind="warning"
                  title="Closure changed after you opened it"
                  tabindex="-1"
                >
                  <p class="text-sm">
                    Nothing was saved and your entries are kept. Reload the closure to see the current version, then make your change again.
                  </p>
                  <button
                    id="closure-reload"
                    type="button"
                    phx-click="reload_closure"
                    class="mt-3 inline-flex min-h-11 items-center justify-center gap-2 rounded-control border border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas"
                  >
                    <.icon name="hero-arrow-path" class="size-4" /> Reload closure
                  </button>
                </.callout>

                <div :if={@notices != []} id="closure-notices" class="grid gap-2">
                  <.callout
                    :for={notice <- @notices}
                    id={notice.id}
                    data-notice={notice.kind}
                    kind={notice.kind}
                    title={notice.title}
                  >
                    {notice.body}
                  </.callout>
                </div>

                <.input
                  field={@form[:pathway_id]}
                  id="closure-pathway"
                  type="select"
                  label="Pathway"
                  prompt="Choose a pathway"
                  options={pathway_options(@station_data.pathways)}
                  help={pathway_help(@editor_pathway)}
                  class={control_class()}
                />

                <div class="grid gap-1.5">
                  <.input
                    field={@form[:service_id]}
                    id="closure-calendar"
                    type="select"
                    label="Calendar"
                    prompt="Choose a calendar"
                    options={calendar_options(@calendars)}
                    help={calendar_usage_line(@editor_calendar)}
                    class={control_class()}
                  />

                  <%!--
                  The read-only service dates of the chosen calendar. They are a
                  disclosure, not an editor: the grid is a preview of the saved
                  calendar, and the only controls are the month navigation and
                  the link to the calendar page that owns any date change.
                  --%>
                  <div
                    :if={@editor_calendar}
                    id="closure-calendar-actions"
                    class="-mt-1 flex flex-wrap items-center gap-x-5"
                  >
                    <button
                      id="closure-dates-toggle"
                      type="button"
                      phx-click="toggle_dates"
                      aria-expanded={to_string(@dates_open?)}
                      aria-controls="closure-dates"
                      class="inline-flex min-h-11 items-center gap-1 text-sm font-[650] text-action hover:underline"
                    >
                      <.icon
                        name="hero-chevron-right"
                        class={["size-4 transition-transform", @dates_open? && "rotate-90"]}
                      />
                      {if @dates_open?, do: "Hide service dates", else: "Show service dates"}
                    </button>
                    <a
                      :if={@calendar_href}
                      id="closure-calendar-link"
                      href={@calendar_href}
                      class="inline-flex min-h-11 items-center gap-1.5 text-sm font-[650] text-action no-underline hover:underline"
                    >
                      Open calendar<.icon name="hero-arrow-top-right-on-square" class="size-4" />
                    </a>
                  </div>

                  <div
                    :if={@editor_calendar}
                    id="closure-dates"
                    hidden={not @dates_open?}
                    class="rounded-control border border-subtle p-3"
                  >
                    <div :if={@dates_month} class="flex items-center justify-between gap-2">
                      <button
                        id="closure-dates-prev"
                        type="button"
                        phx-click="dates_step"
                        phx-value-step="prev"
                        aria-label={"Show " <> @dates_prev_label}
                        class="inline-flex size-11 items-center justify-center rounded-control border border-control bg-white text-strong hover:bg-canvas"
                      >
                        <.icon name="hero-chevron-left" class="size-4" />
                      </button>
                      <p id="closure-dates-month" class="text-sm font-[650] text-strong">
                        {@dates_month_label}
                      </p>
                      <button
                        id="closure-dates-next"
                        type="button"
                        phx-click="dates_step"
                        phx-value-step="next"
                        aria-label={"Show " <> @dates_next_label}
                        class="inline-flex size-11 items-center justify-center rounded-control border border-control bg-white text-strong hover:bg-canvas"
                      >
                        <.icon name="hero-chevron-right" class="size-4" />
                      </button>
                    </div>

                    <p
                      :if={@dates_missing?}
                      id="closure-dates-missing"
                      class="text-sm text-muted"
                    >
                      This calendar is no longer in this service version. Choose another calendar before saving; your entries are kept.
                    </p>

                    <CalendarEditorComponents.month_table
                      :if={@dates_month_grid}
                      id="closure-dates-months"
                      month_grid={@dates_month_grid}
                      weekly?={not is_nil(@dates_calendar.calendar)}
                      today={@dates_calendar.today}
                      label={"Read-only service dates for " <> @editor_calendar.label}
                    />

                    <p
                      :if={@dates_no_active?}
                      id="closure-dates-none"
                      class="mt-2 text-sm text-muted"
                    >
                      This calendar has no active service dates.
                    </p>
                  </div>
                </div>

                <fieldset class="min-w-0">
                  <legend class="text-[13px] font-[650] text-base-content">Closure window</legend>
                  <div class="mt-2 flex flex-wrap items-end gap-x-3 gap-y-2">
                    <.input
                      field={@form[:start_time]}
                      id="closure-start"
                      type="text"
                      label="Starts at"
                      inputmode="numeric"
                      autocomplete="off"
                      spellcheck="false"
                      class={time_class()}
                      phx-debounce="blur"
                    />
                    <.input
                      field={@form[:end_time]}
                      id="closure-end"
                      type="text"
                      label="Ends at"
                      inputmode="numeric"
                      autocomplete="off"
                      spellcheck="false"
                      help="Service time. Use 24-hour time. For 2 AM the next day, enter 26:00."
                      class={time_class()}
                      phx-debounce="blur"
                    />
                  </div>
                </fieldset>

                <.input
                  field={@form[:note]}
                  id="closure-note"
                  type="textarea"
                  rows="2"
                  label="Note (optional)"
                  help="For your team. Not included in GTFS exports."
                  class={textarea_class()}
                  phx-debounce="blur"
                />

                <div class="rounded-control bg-canvas px-4 py-3">
                  <p id="closure-summary" class="text-sm text-strong">
                    {closure_summary(@form.params, @editor_pathway, @editor_calendar)}
                  </p>
                  <a
                    :if={is_nil(@preview_unavailable)}
                    id="preview-closure-impact"
                    href={@preview_href}
                    class="-mb-1.5 inline-flex min-h-11 items-center gap-1.5 text-sm font-[650] text-action no-underline hover:underline"
                  >
                    Preview access impact<.icon name="hero-arrow-right" class="size-4" />
                  </a>
                  <p
                    :if={@preview_unavailable}
                    id="closure-preview-unavailable"
                    class="mt-1.5 text-[13px] text-muted"
                  >
                    {@preview_unavailable}
                  </p>
                </div>

                <p id="closure-scope" class="text-[13px] text-muted">
                  Saving updates this version immediately. Full exports include this closure.
                </p>
              </div>

              <footer
                id="closure-actions"
                class="sticky bottom-0 z-10 flex flex-wrap items-center justify-end gap-2 border-t border-subtle bg-white px-5 py-4"
              >
                <div
                  :if={@editor_mode == :edit}
                  id="delete-closure-wrap"
                  class="mr-auto max-sm:basis-full"
                >
                  <.button
                    id="delete-closure"
                    type="button"
                    phx-click="request_delete"
                    variant="secondary"
                    disabled={@delete_pending?}
                    class="min-h-11 gap-1.5 rounded-control border-control bg-white px-3 text-sm font-[650] text-error hover:bg-error/10 disabled:pointer-events-none disabled:opacity-60"
                  >
                    <.icon name="hero-trash" class="size-4" /> Delete closure
                  </.button>
                </div>
                <.button
                  id="discard-closure"
                  type="button"
                  phx-click="discard_closure"
                  variant="secondary"
                  class="min-h-11 rounded-control border-control bg-white px-4 text-sm font-[650] text-strong hover:bg-canvas"
                >
                  {if @dirty?, do: "Discard edits", else: "Close"}
                </.button>
                <.button
                  id="save-closure"
                  type="submit"
                  disabled={@stale?}
                  title={@stale? && "Reload the closure before saving"}
                  phx-disable-with="Saving…"
                  class="min-h-11 min-w-[7.5rem] rounded-control bg-action px-4 text-sm font-[650] text-white hover:bg-evo-action-hover disabled:pointer-events-none disabled:opacity-60"
                >
                  Save closure
                </.button>
              </footer>
            </.form>

            <%!--
            The unsaved-edits guard: one explicit choice for every departure that
            would drop typed values — an in-app link, another row, or the start of
            a new closure.
            --%>
            <.confirm_dialog
              id="closure-dirty-dialog"
              open={@pending_action != nil}
              title="Discard closure edits?"
              confirm_label="Discard edits"
              cancel_label="Keep editing"
              pending_label="Discarding…"
              on_confirm="discard_edits"
              on_cancel="keep_editing"
              described_by="closure-dirty-body"
              confirm_variant="primary"
              return_focus_id="closure-editor-title"
            >
              <p id="closure-dirty-body">{@dirty_dialog_body}</p>
            </.confirm_dialog>

            <%!--
            The delete confirmation: the one explicit choice before a closure
            is removed. It names the saved row it would remove and states that
            the calendar stays, and its confirmation is disabled while the
            context's delete is in flight.
            --%>
            <.confirm_dialog
              id="closure-delete-dialog"
              open={@delete_confirm?}
              title="Delete this closure?"
              confirm_label="Delete closure"
              cancel_label="Keep closure"
              pending_label="Deleting…"
              on_confirm="confirm_delete"
              on_cancel="cancel_delete"
              pending={@delete_pending?}
              described_by="closure-delete-body"
              confirm_variant="primary"
              return_focus_id="delete-closure"
            >
              <div id="closure-delete-body">
                <div :if={@delete_target} id="closure-delete-summary">
                  <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1">
                    <dt class="text-muted">Pathway</dt>
                    <dd id="closure-delete-pathway" class="text-strong">
                      {@delete_target.pathway_label}
                      <span class="font-mono text-[12px] text-muted">
                        {@delete_target.pathway_id}
                      </span>
                    </dd>
                    <dt class="text-muted">Calendar</dt>
                    <dd id="closure-delete-calendar" class="text-strong">
                      {@delete_target.calendar_label}
                    </dd>
                    <dt class="text-muted">Window</dt>
                    <dd id="closure-delete-window" class="tabular-nums text-strong">
                      {@delete_target.window}
                      <span :if={@delete_target.window_note} class="text-muted">
                        · {@delete_target.window_note}
                      </span>
                    </dd>
                  </dl>
                  <p class="mt-3">
                    Deleting changes this version immediately.
                    <span id="closure-delete-calendar-note">{@delete_target.calendar_label}</span>
                    stays unchanged.
                  </p>
                </div>
                <p :if={is_nil(@delete_target)} id="closure-delete-unavailable">
                  This closure is no longer available in this service version.
                </p>
              </div>
            </.confirm_dialog>
          </aside>

          <section
            :if={is_nil(@blocked)}
            id="closure-locator"
            aria-labelledby="closure-locator-title"
            class="min-w-0 rounded-card border border-subtle bg-white lg:col-start-1 lg:row-start-2"
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
      </div>
    </Layouts.app>
    """
  end

  # The editor's controls carry the design system's control treatment, plus the
  # invalid state the input component marks with `aria-invalid`.
  defp control_class do
    "h-11 w-full rounded-control border border-control bg-white px-3 text-sm text-strong " <>
      "aria-[invalid=true]:border-2 aria-[invalid=true]:border-error"
  end

  defp time_class do
    "h-11 w-[6.5rem] rounded-control border border-control bg-white px-3 font-mono " <>
      "text-sm tabular-nums text-strong aria-[invalid=true]:border-2 aria-[invalid=true]:border-error"
  end

  defp textarea_class do
    "min-h-16 w-full resize-y rounded-control border border-control bg-white px-3 py-2.5 text-sm " <>
      "text-strong aria-[invalid=true]:border-2 aria-[invalid=true]:border-error"
  end

  # Why the access preview cannot be offered yet, or nil when it can. A new
  # closure has nothing saved to preview, a stale one has to be reloaded first,
  # and a dirty one has to be saved or discarded; only then can the calendar's
  # own reason (no active dates, no usable zone) apply.
  defp preview_unavailable(assigns) do
    cond do
      assigns.editor_mode == nil -> nil
      assigns.editor_mode == :new -> "Save the closure to preview its access impact."
      assigns.stale? -> "Reload the closure before previewing the saved result."
      assigns.dirty? -> "Save or discard your edits to preview the saved closure."
      true -> assigns.preview_reason
    end
  end

  # The calendar page's own address, encoded the way its own links are, so a
  # service ID with a slash, a percent sign or a space stays one exact value.
  # Like the other render helpers, it derives the chosen calendar from the raw
  # assigns rather than from a value the same render is still computing.
  defp calendar_href(assigns) do
    case editor_calendar(assigns) do
      %{service_id: service_id} ->
        "/gtfs/#{assigns.current_gtfs_version.id}/calendars/show?service_id=" <>
          URI.encode_www_form(service_id)

      _other ->
        nil
    end
  end

  # One read-only month, built by the same native evaluator the calendar page
  # uses. The grid exists only while the disclosure is open on a loaded calendar,
  # so a closed disclosure renders no dates at all.
  defp dates_month_grid(%{
         dates_open?: true,
         dates_month: %Date{} = month,
         dates_calendar: %{} = calendar
       }) do
    ServiceDates.month_grid(calendar.calendar, calendar.exceptions, month)
  end

  defp dates_month_grid(_assigns), do: nil

  defp dates_month_label(%{dates_open?: true, dates_month: %Date{} = month}),
    do: CalendarComponents.month_title(month)

  defp dates_month_label(_assigns), do: nil

  # The next and previous buttons name the month they would show, so a reader who
  # cannot see the grid still learns what the control does.
  defp dates_step_label(%{dates_open?: true, dates_month: %Date{} = month}, offset) do
    month |> CalendarComponents.shift_month(offset) |> CalendarComponents.month_title()
  end

  defp dates_step_label(_assigns, _offset), do: nil

  defp dates_no_active?(%{dates_open?: true, dates_calendar: %{active_dates: []}}), do: true
  defp dates_no_active?(_assigns), do: false

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
