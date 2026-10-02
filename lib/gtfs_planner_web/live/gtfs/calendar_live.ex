defmodule GtfsPlannerWeb.Gtfs.CalendarLive do
  @moduledoc """
  Create and detail editor for one editable service calendar.

  The screen is a form over the real `Gtfs.Calendars` contracts: the fields are a
  `to_form` view of a plain parameter map, the retained source fingerprint comes
  from the `Gtfs.fetch_calendar/3` load that also supplied the periods, preview
  and usage, and every write goes through create, a reviewed command, or a
  reviewed delete. The fingerprint is never refreshed immediately before a save,
  so a change committed in another session returns `:stale_review` and the
  entered values stay on screen.

  Schedule fields and the independent period/date actions are separate concerns:
  adding a break, adding service dates, removing a stored date change, or
  switching versions while the schedule fields are dirty opens an explicit
  save-or-discard dialog and writes nothing on cancel.

  States stay distinct: an unreadable scope renders not-found, a lost connection
  renders the retry callout with an explanation, and a failed or stale save keeps
  the draft. A calendar whose imported metadata has no name shows its service ID
  as the fallback label and never invents a stored name. A calendar whose stored end
  date is before its start date opens with an error callout and its stored dates, and
  only a corrected range can be saved; conversion, breaks and single-date changes wait
  until it is.

  Outcomes render next to what changed: `message_area` is `:schedule` for a save,
  `:changes` for a date change and `:page` for duplicate and delete, so a message
  is never far from the control that caused it. `status_message` and
  `error_message` hold a title or a `{title, body}` pair.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.Gtfs.CalendarComponents
  alias GtfsPlannerWeb.Gtfs.CalendarEditorComponents, as: Editor

  import GtfsPlannerWeb.PlannerComponents,
    only: [form_error_summary: 1, message: 1, unsaved_badge: 1]

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @weekday_fields ~w(monday tuesday wednesday thursday friday saturday sunday)
  @weekday_options [
    {"Monday", "monday"},
    {"Tuesday", "tuesday"},
    {"Wednesday", "wednesday"},
    {"Thursday", "thursday"},
    {"Friday", "friday"},
    {"Saturday", "saturday"},
    {"Sunday", "sunday"}
  ]
  @schedule_types [
    {"Not specified", ""},
    {"Weekday", "Weekday"},
    {"Weekend", "Weekend"},
    {"Saturday", "Saturday"},
    {"Sunday", "Sunday"},
    {"Other", "Other"}
  ]
  @typicality_options [
    {"Not specified", "0"},
    {"Typical service", "1"},
    {"Extra service", "2"},
    {"Reduced holiday service", "3"},
    {"Reduced non-holiday service", "4"},
    {"Added holiday service", "5"},
    {"Other service", "6"}
  ]
  @presets [
    {"Weekdays", ~w(monday tuesday wednesday thursday friday)},
    {"Weekends", ~w(saturday sunday)},
    {"Every day", @weekday_fields}
  ]
  @params_as :calendar
  # The fields inside the "More details" disclosure. An error on one of them
  # opens the disclosure so it is not hidden inside a collapsed section.
  @details_fields ~w(service_schedule_name service_schedule_type service_schedule_typicality
    rating_start_date rating_end_date rating_description)a

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:load_state, :loading)
     |> assign(:source, nil)
     |> assign(:service_id, nil)
     |> assign(:fingerprint, nil)
     |> assign(:usage, empty_usage())
     |> assign(:kind, :weekly)
     |> assign(:periods, empty_periods())
     |> assign(:preview_month, nil)
     |> assign(:month_grid, nil)
     |> assign(:zone, nil)
     |> assign(:today, Date.utc_today())
     |> assign(:warnings, [])
     |> assign(:params, %{})
     |> assign(:baseline, nil)
     |> assign(:field_errors, %{})
     |> assign(:details_open?, false)
     |> assign(:form, to_form(%{}, as: @params_as))
     |> assign(:break_params, %{"first_date" => "", "last_date" => ""})
     |> assign(:break_form, to_form(%{"first_date" => "", "last_date" => ""}, as: :break))
     |> assign(:exception_form, to_form(%{"date" => ""}, as: :exception))
     |> assign(:weekday_options, @weekday_options)
     |> assign(:schedule_types, @schedule_types)
     |> assign(:typicality_options, @typicality_options)
     |> assign(:presets, @presets)
     |> assign(:review_dialog, nil)
     |> assign(:pending_navigation, nil)
     |> assign(:pending_action, nil)
     |> assign(:delete_block, nil)
     |> assign(:date_block, nil)
     |> assign(:pending?, false)
     |> assign(:status_message, nil)
     |> assign(:error_message, nil)
     |> assign(:message_area, :schedule)
     |> assign(:rejected?, false)
     |> assign(:dirty?, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :new ->
        if socket.assigns.baseline == nil do
          {:noreply, new_calendar(socket)}
        else
          {:noreply, socket}
        end

      :show ->
        service_id = params["service_id"]

        cond do
          service_id in [nil, ""] ->
            {:noreply, not_found(socket)}

          socket.assigns.load_state == :ready and socket.assigns.service_id == service_id ->
            {:noreply, move_preview(socket, params["month"])}

          true ->
            {:noreply, load_calendar(socket, service_id)}
        end
    end
  end

  @impl true
  def handle_event("retry", _params, socket) do
    case socket.assigns.live_action do
      :new ->
        {:noreply, new_calendar(socket)}

      :show ->
        {:noreply,
         load_calendar(assign(socket, :load_state, :loading), socket.assigns.service_id)}
    end
  end

  ## Schedule form

  @impl true
  def handle_event("validate", %{"calendar" => submitted}, socket) do
    params = merge_params(socket, submitted)
    params = suggest_service_id(socket, params)

    # A date entered in the specific-dates picker becomes a draft chip as soon as
    # the picker reports a complete date, so the drafted dates are part of the
    # same form values the create command reads.
    case {socket.assigns.live_action, params["date_input"]} do
      {:new, input} when input != "" -> draft_date(socket, params, input)
      _ -> {:noreply, put_params(socket, params, errors: [])}
    end
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  # The disclosure is a native `<details>`, so the browser owns the toggle and the
  # summary click only keeps the server's `open` attribute in step. Without this
  # every re-render strips the attribute and closes the section mid-edit.
  @impl true
  def handle_event("toggle_details", _params, socket) do
    {:noreply, assign(socket, :details_open?, not socket.assigns.details_open?)}
  end

  @impl true
  def handle_event("set_kind", %{"kind" => kind}, socket) when kind in ["weekly", "dates_only"] do
    {:noreply, put_params(socket, Map.put(socket.assigns.params, "kind", kind), errors: [])}
  end

  def handle_event("set_kind", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("preset_days", %{"preset" => preset}, socket) do
    case Enum.find(@presets, fn {label, _days} -> label == preset end) do
      {_label, days} ->
        params = socket.assigns.params |> Map.put("weekdays", days) |> Map.put("kind", "weekly")
        {:noreply, put_params(socket, params, errors: [])}

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_draft_date", %{"date" => iso}, socket) do
    dates = Enum.reject(socket.assigns.params["dates"], &(&1 == iso))
    {:noreply, put_params(socket, Map.put(socket.assigns.params, "dates", dates), errors: [])}
  end

  @impl true
  def handle_event("submit_form", %{"calendar" => submitted}, socket) do
    params = merge_params(socket, submitted)
    save(socket, params)
  end

  def handle_event("submit_form", _params, socket), do: {:noreply, socket}

  ## Reviewed actions

  # The break range is server state as well, so a re-render keeps the dates the
  # user entered instead of replacing them with the previous render's values.
  @impl true
  def handle_event("validate_break", %{"break" => submitted}, socket) do
    params = merge_break_params(socket, submitted)

    {:noreply,
     socket
     |> assign(:break_params, params)
     |> assign(:break_form, to_form(params, as: :break))}
  end

  def handle_event("validate_break", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("add_break", %{"break" => submitted}, socket) do
    params = merge_break_params(socket, submitted)
    socket = assign(socket, :break_form, to_form(params, as: :break))

    with {:ok, first_date} <- parse_date(params["first_date"]),
         {:ok, last_date} <- parse_date(params["last_date"]),
         :ok <- ordered_range(first_date, last_date) do
      guard_or_run(socket, {:add_break, socket.assigns.service_id, first_date, last_date})
    else
      :error ->
        {:noreply,
         put_error(
           socket,
           :changes,
           "Choose the first and last day off. For a single day, choose it twice."
         )}

      {:error, message} ->
        {:noreply, put_error(socket, :changes, message)}
    end
  end

  def handle_event("add_break", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("add_dates", %{"exception" => submitted}, socket) do
    case parse_date(Map.get(submitted, "date", "")) do
      {:ok, date} ->
        guard_or_run(socket, {:put_exceptions, socket.assigns.service_id, [date], :added})

      :error ->
        {:noreply, put_error(socket, :changes, "Choose a valid date to add.")}
    end
  end

  def handle_event("add_dates", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("remove_date", %{"date" => iso}, socket) do
    case parse_date(iso) do
      {:ok, date} ->
        guard_or_run(socket, {:remove_exceptions, socket.assigns.service_id, [date]})

      :error ->
        {:noreply, put_error(socket, :changes, "That date change could not be read.")}
    end
  end

  @impl true
  def handle_event("remove_break", %{"dates" => dates}, socket) do
    case parse_dates(dates) do
      {:ok, []} ->
        {:noreply,
         put_error(socket, :changes, "That break has no stored date changes to remove.")}

      {:ok, parsed} ->
        guard_or_run(socket, {:remove_exceptions, socket.assigns.service_id, parsed})

      :error ->
        {:noreply, put_error(socket, :changes, "That break could not be read.")}
    end
  end

  @impl true
  def handle_event("calendar_depart", %{"path" => path}, socket) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      {:noreply, assign(socket, :pending_navigation, path)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("duplicate", _params, %{assigns: %{dirty?: true}} = socket) do
    {:noreply, assign(socket, :pending_action, :duplicate)}
  end

  def handle_event("duplicate", _params, socket) do
    audit = audit_context(socket)

    case Gtfs.duplicate_calendar(socket.assigns.service_id, %{}, audit) do
      {:ok, %{service_id: copy_id}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Duplicated as #{copy_id}.")
         |> push_navigate(to: detail_path(socket, copy_id))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_error(:page, write_error_message(reason, :duplicate))
         |> focus_message()}
    end
  end

  @impl true
  def handle_event("delete", _params, socket) do
    guard_or_run(socket, {:delete, socket.assigns.service_id})
  end

  @impl true
  def handle_event("apply_review", _params, socket) do
    case socket.assigns.review_dialog do
      %{command: command, fingerprint: fingerprint} ->
        socket = assign(socket, :review_dialog, nil)

        case Gtfs.apply_calendar_change(command, fingerprint, audit_context(socket)) do
          {:ok, %{action: :deleted}} ->
            {:noreply,
             socket
             |> put_flash(:info, "Deleted #{socket.assigns.service_id}.")
             |> push_navigate(to: list_path(socket))}

          {:ok, result} ->
            {:noreply, after_write(socket, command, result)}

          {:error, reason} ->
            {:noreply, write_failed(socket, reason, command)}
        end

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_review", _params, socket) do
    {:noreply, assign(socket, :review_dialog, nil)}
  end

  # Discard changes drops typed work, so it asks first through the same dialog as
  # every other action that would drop it.
  @impl true
  def handle_event("ask_discard", _params, socket) do
    {:noreply, assign(socket, :pending_action, :discard)}
  end

  @impl true
  def handle_event("discard_changes", _params, socket) do
    socket =
      if socket.assigns.pending_action == :discard,
        do: push_event(socket, "focus_scoped_target", %{id: "calendar-name"}),
        else: socket

    {:noreply, socket |> reset_draft() |> continue_pending()}
  end

  @impl true
  def handle_event("keep_editing", _params, socket) do
    {:noreply, assign(socket, pending_navigation: nil, pending_action: nil)}
  end

  ## Preview navigation

  @impl true
  def handle_event("preview_keys", %{"key" => key}, socket)
      when key in ["ArrowLeft", "ArrowRight", "Home"] do
    {:noreply, move_preview(socket, preview_target(socket, key))}
  end

  def handle_event("preview_keys", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("preview_step", %{"step" => step}, socket) do
    {:noreply, move_preview(socket, preview_step(socket, step))}
  end

  ## Version switches

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    switch_version(socket, version_id)
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    switch_version(socket, version_id)
  end

  ## Loading

  defp new_calendar(socket) do
    params = creation_params()

    socket
    |> assign(:page_title, "Create calendar")
    |> assign(:load_state, :ready)
    |> assign(:service_id, nil)
    |> assign(:source, nil)
    |> assign(:fingerprint, nil)
    |> assign(:usage, empty_usage())
    |> assign(:kind, :weekly)
    |> assign(:periods, empty_periods())
    |> assign(:warnings, [])
    |> put_params(params, baseline: params, errors: [])
    |> assign_preview(socket.assigns.today || Date.utc_today())
  end

  defp load_calendar(socket, service_id) when is_binary(service_id) do
    socket = assign(socket, :service_id, service_id)
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.fetch_calendar(organization_id, version_id, service_id) do
      {:ok, source} ->
        apply_source(socket, source)

      {:error, :not_found} ->
        not_found(socket)

      {:error, :unavailable} ->
        socket
        |> assign(:load_state, :unavailable)
        |> assign(:source, nil)
        |> assign(:params, %{})
        |> assign(:baseline, nil)
        |> assign(:form, to_form(%{}, as: @params_as))
    end
  end

  defp load_calendar(socket, _service_id), do: not_found(socket)

  defp not_found(socket) do
    socket
    |> assign(:page_title, "Calendar")
    |> assign(:load_state, :not_found)
    |> assign(:source, nil)
    |> assign(:service_id, nil)
    |> assign(:params, %{})
    |> assign(:baseline, nil)
    |> assign(:form, to_form(%{}, as: @params_as))
  end

  # One coherent load supplies the form source, its retained fingerprint, the
  # derived periods, the effective dates, the warnings, the resolved agency clock
  # and the grouped usage.
  defp apply_source(socket, source) do
    params = params_from_source(source)

    socket
    |> assign(:page_title, source.attributes && source.attributes.service_description)
    |> assign(:load_state, :ready)
    |> assign(:source, source)
    |> assign(:service_id, to_string(source_payload_value(source, :service_id)))
    |> assign(:fingerprint, source.fingerprint)
    |> assign(:usage, source.usage)
    |> assign(:kind, source.kind)
    |> assign(:today, source.today)
    |> assign(:zone, source.zone)
    |> put_params(params, baseline: params, errors: [])
    |> refresh_derived(source, source.today)
    |> assign(:delete_block, nil)
    |> assign(:date_block, nil)
  end

  # A post-write refresh is a fresh source snapshot, so the retained fingerprint
  # and the dirty baseline both move with it. The outcome is worded from that fresh
  # snapshot, so it reports what is now stored, not what was asked for.
  defp refresh_source(socket, area, {title, body_for}) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.fetch_calendar(organization_id, version_id, socket.assigns.service_id) do
      {:ok, source} ->
        socket
        |> apply_source(source)
        |> put_status(area, {title, body_for.(source)})

      {:error, _reason} ->
        put_error(
          socket,
          area,
          {title, "The calendar could not be reloaded. Reload the page to see the stored values."}
        )
    end
  end

  defp refresh_derived(socket, source, today) do
    socket
    |> assign(:periods, source.periods)
    |> assign(:warnings, source.warnings)
    |> assign(:kind, source.kind)
    |> assign_preview(socket.assigns.preview_month || Date.new!(today.year, today.month, 1))
  end

  # One month at a time: the strip in the changes card carries the long view, and the
  # preview beside the form has room for a readable month.
  defp assign_preview(socket, month) do
    first = Date.new!(month.year, month.month, 1)
    source = socket.assigns.source
    calendar = preview_calendar(socket, source)

    exceptions =
      if source && source.kind == :weekly && socket.assigns.params["kind"] == "dates_only",
        do: Enum.map(source.active_dates, &%{date: &1, exception_type: 1}),
        else: (source && source.exceptions) || []

    exceptions =
      exceptions ++
        Enum.map(socket.assigns.params["dates"] || [], fn iso ->
          %{date: Date.from_iso8601!(iso), exception_type: 1}
        end)

    assign(socket,
      month_grid: ServiceDates.month_grid(calendar, exceptions, first),
      preview_month: first
    )
  end

  defp preview_calendar(socket, source) do
    case {socket.assigns.params["kind"], weekly_attrs(socket.assigns.params)} do
      {"dates_only", _} -> nil
      {"weekly", {:ok, attrs}} -> struct(GtfsPlanner.Gtfs.Calendar, attrs)
      _ -> stored_calendar(source)
    end
  end

  # The form only falls back to the stored row while its own range is unusable. A
  # stored reversed range has no dates to draw, so the preview stays empty until
  # the form holds a valid range.
  defp stored_calendar(%{coverage_error: nil, calendar: calendar}), do: calendar
  defp stored_calendar(_source), do: nil

  defp move_preview(socket, month) do
    assign_preview(socket, month)
  end

  defp preview_target(socket, "ArrowLeft"), do: shift_month(socket.assigns.preview_month, -1)
  defp preview_target(socket, "ArrowRight"), do: shift_month(socket.assigns.preview_month, 1)
  defp preview_target(socket, "Home"), do: preview_step(socket, "today")

  defp preview_step(socket, "next"), do: shift_month(socket.assigns.preview_month, 1)
  defp preview_step(socket, "prev"), do: shift_month(socket.assigns.preview_month, -1)

  defp preview_step(socket, _today),
    do: Date.new!(socket.assigns.today.year, socket.assigns.today.month, 1)

  defp shift_month(%Date{} = month, offset) do
    total = month.year * 12 + (month.month - 1) + offset
    Date.new!(div(total, 12), rem(total, 12) + 1, 1)
  end

  ## Form parameters

  defp creation_params do
    %{
      "service_id" => "",
      "name" => "",
      "kind" => "weekly",
      "weekdays" => ~w(monday tuesday wednesday thursday friday),
      "start_date" => "",
      "end_date" => "",
      "date_input" => "",
      "dates" => [],
      "service_schedule_name" => "",
      "service_schedule_type" => "",
      "service_schedule_typicality" => "0",
      "rating_start_date" => "",
      "rating_end_date" => "",
      "rating_description" => ""
    }
  end

  defp params_from_source(source) do
    attributes = source.attributes

    %{
      "service_id" => to_string(source_payload_value(source, :service_id)),
      "name" => attribute_value(attributes, :service_description, ""),
      "kind" => to_string(source.kind),
      "date_input" => "",
      "dates" => []
    }
    |> Map.merge(weekly_form_values(source.calendar))
    |> Map.merge(metadata_form_values(attributes))
  end

  defp weekly_form_values(calendar) do
    %{
      "weekdays" =>
        Enum.filter(@weekday_fields, fn field ->
          calendar && Map.get(calendar, String.to_existing_atom(field)) == 1
        end),
      "start_date" => date_string(calendar && calendar.start_date),
      "end_date" => date_string(calendar && calendar.end_date)
    }
  end

  # Every optional schedule attribute keeps its own empty value, so a cleared
  # field is submitted as blank rather than as the previous stored text.
  defp metadata_form_values(attributes) do
    %{
      "service_schedule_name" => attribute_value(attributes, :service_schedule_name, ""),
      "service_schedule_type" => attribute_value(attributes, :service_schedule_type, ""),
      "service_schedule_typicality" =>
        to_string(attribute_value(attributes, :service_schedule_typicality, 0)),
      "rating_start_date" => date_string(attribute_value(attributes, :rating_start_date, nil)),
      "rating_end_date" => date_string(attribute_value(attributes, :rating_end_date, nil)),
      "rating_description" => attribute_value(attributes, :rating_description, "")
    }
  end

  defp attribute_value(nil, _field, default), do: default
  defp attribute_value(attributes, field, default), do: Map.get(attributes, field) || default

  # The submitted map only carries the controls the form owns; the draft date list
  # and the kind selection are server state, so they are preserved deliberately.
  defp merge_params(socket, submitted) when is_map(submitted) do
    params = socket.assigns.params

    %{
      params
      | "name" => value(submitted, "name", params["name"]),
        "kind" =>
          if(submitted["kind"] in ["weekly", "dates_only"],
            do: submitted["kind"],
            else: params["kind"]
          ),
        "weekdays" =>
          case Map.fetch(submitted, "weekdays") do
            {:ok, days} when is_list(days) -> Enum.filter(days, &(&1 in @weekday_fields))
            :error -> []
            _other -> []
          end,
        "start_date" => value(submitted, "start_date", params["start_date"]),
        "end_date" => value(submitted, "end_date", params["end_date"]),
        "date_input" => value(submitted, "date_input", params["date_input"]),
        "service_id" => value(submitted, "service_id", params["service_id"]),
        "service_schedule_name" =>
          value(submitted, "service_schedule_name", params["service_schedule_name"]),
        "service_schedule_type" =>
          value(submitted, "service_schedule_type", params["service_schedule_type"]),
        "service_schedule_typicality" =>
          if(
            submitted["service_schedule_typicality"] in Enum.map(
              @typicality_options,
              &elem(&1, 1)
            ),
            do: submitted["service_schedule_typicality"],
            else: params["service_schedule_typicality"]
          ),
        "rating_start_date" => value(submitted, "rating_start_date", params["rating_start_date"]),
        "rating_end_date" => value(submitted, "rating_end_date", params["rating_end_date"]),
        "rating_description" =>
          value(submitted, "rating_description", params["rating_description"])
    }
  end

  defp merge_params(socket, _submitted), do: socket.assigns.params

  defp value(submitted, key, default) do
    case Map.fetch(submitted, key) do
      {:ok, value} when is_binary(value) -> String.trim(value)
      {:ok, nil} -> ""
      _other -> default
    end
  end

  defp merge_break_params(socket, submitted) do
    current = socket.assigns.break_params

    %{
      "first_date" => value(submitted, "first_date", current["first_date"]),
      "last_date" => value(submitted, "last_date", current["last_date"])
    }
  end

  # The suggested service ID is visible and editable until the user types their own:
  # it follows the name while it is empty or still the suggestion for the previous
  # name. It is never derived for an existing calendar, whose service ID cannot change.
  defp suggest_service_id(%{assigns: %{live_action: :new}} = socket, params) do
    previous_suggestion = service_id_from_name(socket.assigns.params["name"] || "")

    if params["service_id"] in ["", previous_suggestion] do
      Map.put(params, "service_id", service_id_from_name(params["name"]))
    else
      params
    end
  end

  defp suggest_service_id(_socket, params), do: params

  defp service_id_from_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> String.slice(0, 60)
  end

  # `rejected: true` marks a rejected submit, the only time the error summary shows:
  # live validation and typing are not a rejection.
  defp put_params(socket, params, opts) do
    errors = Keyword.get(opts, :errors, [])
    baseline = Keyword.get(opts, :baseline, socket.assigns.baseline)

    socket
    |> assign(:params, params)
    |> assign(:baseline, baseline)
    |> assign(:rejected?, Keyword.get(opts, :rejected, false) and errors != [])
    |> assign(
      :field_errors,
      Map.new(errors, fn {field, messages} -> {field, List.wrap(messages)} end)
    )
    |> assign(:form, to_form(params, as: @params_as, errors: errors))
    |> assign(
      :details_open?,
      socket.assigns.details_open? or
        Enum.any?(errors, fn {field, _} -> field in @details_fields end)
    )
    |> assign(:dirty?, baseline != nil and params != baseline)
    |> maybe_clear_messages(opts)
    |> assign_preview(socket.assigns.preview_month || socket.assigns.today || Date.utc_today())
  end

  defp maybe_clear_messages(socket, opts) do
    if Keyword.get(opts, :clear_messages, true) do
      assign(socket, error_message: nil, status_message: nil)
    else
      socket
    end
  end

  defp reject_input(socket, params, errors) do
    put_params(socket, params, errors: errors)
  end

  # A rejected submit lands focus on the first invalid field, or on the summary when
  # the failing control cannot take focus.
  defp reject_submit(socket, params, errors) do
    socket
    |> put_params(params, errors: errors, rejected: true)
    |> focus_field_error()
  end

  defp reset_draft(socket) do
    params = socket.assigns.baseline || creation_params()

    put_params(socket, params, baseline: params, errors: [])
  end

  ## Saving

  defp save(socket, params) do
    case params_to_command(socket, params) do
      {:ok, :create, attrs} -> create(socket, params, attrs)
      {:ok, command} -> review_or_apply(socket, params, command)
      {:error, errors} -> {:noreply, reject_submit(socket, params, errors)}
    end
  end

  defp create(socket, params, attrs) do
    case Gtfs.create_calendar(attrs, audit_context(socket)) do
      {:ok, %{service_id: service_id}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created #{service_id}.")
         |> push_navigate(to: detail_path(socket, service_id))}

      {:error, reason} ->
        {:noreply, reject_write(socket, params, reason, :create)}
    end
  end

  # An existing calendar's schedule fields are a reviewed save. The retained
  # fingerprint loaded with the source is sent as-is, so another session's commit
  # is detected instead of silently overwritten.
  defp review_or_apply(socket, params, command) do
    socket = assign(socket, :pending?, true)
    audit = audit_context(socket)
    fingerprints = %{socket.assigns.service_id => socket.assigns.fingerprint}

    case Gtfs.review_calendar_change(command, fingerprints, audit) do
      {:ok, review} ->
        socket = assign(socket, :pending?, false)

        if confirm_required?(command, review) do
          {:noreply, assign(socket, :review_dialog, review_dialog(command, review))}
        else
          apply_reviewed(socket, command, review)
        end

      {:error, reason} ->
        {:noreply, socket |> assign(:pending?, false) |> reject_write(params, reason, command)}
    end
  end

  # The dialog keeps the command and its reviewed fingerprint together, so
  # confirming applies exactly the reviewed change and cancelling writes nothing.
  defp review_dialog(command, review) do
    %{
      command: command,
      fingerprint: review.fingerprint,
      changes: review.changes,
      warnings: review.warnings
    }
  end

  defp apply_reviewed(socket, command, review) do
    case Gtfs.apply_calendar_change(command, review.fingerprint, audit_context(socket)) do
      {:ok, result} -> {:noreply, socket |> after_write(command, result) |> focus_after(command)}
      {:error, reason} -> {:noreply, write_failed(socket, reason, command)}
    end
  end

  # A removed row takes its Restore button with it, so focus follows the outcome
  # message; the other commands leave the pressed control in place.
  defp focus_after(socket, {:remove_exceptions, _service_id, _dates}),
    do: push_event(socket, "focus_scoped_target", %{id: "calendar-status"})

  defp focus_after(socket, _command), do: socket

  # Delete, both conversions, and a break removal are always reviewed; a date
  # change is reviewed when it would leave no service at all or when it stores a
  # date outside the regular range.
  defp confirm_required?({:delete, _service_id}, _review), do: true
  defp confirm_required?({:convert, _service_id, _kind, _attrs}, _review), do: true
  defp confirm_required?({:add_break, _service_id, _first, _last}, _review), do: true

  # `put_exceptions` carries its exception type as a fourth element, so both date
  # commands are matched by their real arity.
  defp confirm_required?({:remove_exceptions, _service_id, _dates}, review) do
    date_change_confirmation(review)
  end

  defp confirm_required?({:put_exceptions, _service_id, _dates, _type}, review) do
    date_change_confirmation(review)
  end

  defp confirm_required?({:save, _service_id, _attrs}, review),
    do: date_change_confirmation(review)

  defp confirm_required?(_command, _review), do: false

  defp date_change_confirmation(review) do
    outside_range? = Enum.any?(review.warnings, &match?(%{reason: :outside_range}, &1))
    review.active_date_count == 0 or outside_range?
  end

  defp after_write(socket, _command, %{action: :deleted}) do
    socket
    |> put_flash(:info, "Deleted #{socket.assigns.service_id}.")
    |> push_navigate(to: list_path(socket))
  end

  defp after_write(socket, command, result) do
    refresh_source(socket, area_for(command), result_outcome(result, socket.assigns.kind))
  end

  # Each outcome is a title and a body worded from the source read after the write:
  # what changed, then what the calendar now does.
  defp result_outcome(%{action: :unchanged}, _kind) do
    {"No change was needed.", fn _source -> "The calendar already matches what you see." end}
  end

  defp result_outcome(%{action: :convert, kind: :dates_only}, _kind) do
    {"Converted to chosen dates.",
     fn source ->
       "All #{Wording.count_noun(length(source.active_dates), "service date")} are now stored as individual dates. Trips run on the same days as before."
     end}
  end

  defp result_outcome(%{action: :convert, kind: :weekly}, _kind) do
    {"Converted to a weekly schedule.",
     fn _source ->
       "The calendar now runs on the days and dates you chose. Dates you added individually were kept."
     end}
  end

  defp result_outcome(%{action: :add_break, changed_count: 0}, _kind) do
    {"No change was needed.", fn _source -> "This calendar doesn’t run on any of those days." end}
  end

  defp result_outcome(%{action: :add_break, changed_count: count}, _kind) do
    {"Days off added.",
     fn source ->
       "#{Wording.count_noun(count, "service date")} #{if count == 1, do: "was", else: "were"} removed. " <>
         "#{Wording.count_noun(length(source.active_dates), "service day")} on this calendar."
     end}
  end

  defp result_outcome(%{action: :put_exceptions, changed_count: 0}, _kind) do
    {"No change was needed.", fn _source -> "That date already runs on this calendar." end}
  end

  defp result_outcome(%{action: :put_exceptions}, kind) do
    {if(kind == :weekly, do: "Extra service added.", else: "Service date added."),
     &service_days_line/1}
  end

  defp result_outcome(%{action: :remove_exceptions, changed_count: 0}, _kind) do
    {"No change was needed.", fn _source -> "Nothing was stored for that date." end}
  end

  defp result_outcome(%{action: :remove_exceptions, changed_count: count}, :weekly) do
    {if(count == 1, do: "Regular schedule restored.", else: "#{count} dates restored."),
     fn source ->
       "#{if count == 1, do: "That date follows", else: "Those dates follow"} the regular schedule again. " <>
         service_days_line(source)
     end}
  end

  defp result_outcome(%{action: :remove_exceptions, changed_count: count}, _kind) do
    {if(count == 1, do: "Service date removed.", else: "#{count} service dates removed."),
     &service_days_line/1}
  end

  defp result_outcome(%{changed_count: 0}, _kind) do
    {"No change was needed.", fn _source -> "The calendar already matches what you see." end}
  end

  defp result_outcome(_result, _kind) do
    {"Saved.",
     fn %{usage: usage} ->
       case usage do
         %{trip_count: 0} ->
           "No trips use this calendar yet."

         %{trip_count: trips, routes: routes} ->
           "#{Wording.count_noun(trips, "trip")} on #{Wording.count_noun(length(routes), "route")} now follow this schedule."
       end
     end}
  end

  defp service_days_line(source),
    do: "#{Wording.count_noun(length(source.active_dates), "service day")} on this calendar."

  defp write_failed(socket, reason, command) do
    socket
    |> put_error(area_for(command), write_error_message(reason, command))
    |> assign_delete_block(reason, command)
    |> assign_date_block(reason, command)
    |> focus_message()
  end

  # Where an outcome renders: beside the control that caused it.
  defp area_for({:save, _service_id, _attrs}), do: :schedule
  defp area_for({:convert, _service_id, _kind, _attrs}), do: :schedule
  defp area_for(:create), do: :schedule
  defp area_for(:duplicate), do: :page
  defp area_for({:delete, _service_id}), do: :page
  defp area_for(_command), do: :changes

  defp put_status(socket, area, message) do
    assign(socket, status_message: message, error_message: nil, message_area: area)
  end

  defp put_error(socket, area, message) do
    assign(socket, error_message: message, status_message: nil, message_area: area)
  end

  # Errors are announced when they render; focus goes where the person can act.
  defp focus_field_error(socket) do
    push_event(socket, "focus_form_error", %{
      form_id: "calendar-form",
      fallback_id: "calendar-form-errors"
    })
  end

  defp focus_message(socket) do
    fallback =
      cond do
        socket.assigns.delete_block -> "calendar-delete-blocked-message"
        socket.assigns.date_block -> "calendar-date-error"
        true -> "calendar-error"
      end

    push_event(socket, "focus_form_error", %{form_id: "none", fallback_id: fallback})
  end

  ## Command building

  # A complete picker value becomes a sorted, unique draft chip; an unreadable one
  # is refused on its own control without touching the stored rows.
  defp draft_date(socket, params, input) do
    case parse_date(input) do
      {:ok, date} ->
        iso = Date.to_iso8601(date)

        params =
          params
          |> Map.put("date_input", "")
          |> Map.update!("dates", fn dates -> Enum.sort(Enum.uniq(dates ++ [iso])) end)

        {:noreply, put_params(socket, params, errors: [])}

      :error ->
        {:noreply, reject_input(socket, params, date_error())}
    end
  end

  # Every rule runs, so a rejected submit reports each failing field at once instead
  # of one per attempt. A new calendar also needs its draft dates and feed ID; a blank
  # name already has its own message, so the feed ID it would have suggested is not
  # reported as well.
  defp params_to_command(socket, params) do
    kind = String.to_existing_atom(params["kind"])

    checks = [
      save_name(socket, params),
      metadata_attrs(params),
      save_weekly(socket, kind, params)
    ]

    checks =
      if socket.assigns.live_action == :new,
        do: checks ++ [additions_for(kind, params), new_service_id(params)],
        else: checks

    with {:ok, [name, metadata, weekly | creation]} <- collect(checks) do
      attrs = metadata |> Map.merge(%{name: name, kind: kind}) |> Map.merge(weekly)
      command_for(socket, kind, attrs, creation)
    end
  end

  defp collect(checks) do
    case Enum.flat_map(checks, fn
           {:error, errors} -> errors
           {:ok, _value} -> []
         end) do
      [] -> {:ok, Enum.map(checks, fn {:ok, value} -> value end)}
      errors -> {:error, errors}
    end
  end

  defp new_service_id(%{"name" => name} = params) do
    if String.trim(name) == "", do: {:ok, ""}, else: required_service_id(params)
  end

  defp save_name(socket, params) do
    if socket.assigns.live_action == :show and params["name"] == socket.assigns.baseline["name"],
      do: {:ok, Values.presence(params["name"])},
      else: required_name(params)
  end

  defp save_weekly(socket, kind, params) do
    keys = ["kind", "weekdays", "start_date", "end_date"]

    # A stored reversed range is never "unchanged": the save has to carry a valid
    # range, because planning a save that keeps it would evaluate its dates.
    if socket.assigns.live_action == :show and socket.assigns.source.coverage_error == nil and
         Map.take(params, keys) == Map.take(socket.assigns.baseline, keys),
       do: {:ok, %{}},
       else: weekly_attrs_for(kind, params)
  end

  defp weekly_attrs_for(:weekly, params), do: weekly_attrs(params)
  defp weekly_attrs_for(:dates_only, _params), do: {:ok, %{}}

  # A new calendar carries its own service ID and draft dates; an existing one is
  # either converted to the requested kind or saved in place.
  defp command_for(%{assigns: %{live_action: :new}}, _kind, attrs, [additions, service_id]) do
    {:ok, :create, Map.merge(attrs, Map.merge(%{service_id: service_id}, additions))}
  end

  defp command_for(socket, kind, attrs, []) do
    if socket.assigns.kind == kind do
      {:ok, {:save, socket.assigns.service_id, attrs}}
    else
      {:ok, {:convert, socket.assigns.service_id, kind, attrs}}
    end
  end

  defp additions_for(:dates_only, params), do: additions(params)
  defp additions_for(:weekly, _params), do: {:ok, %{}}

  defp required_name(params) do
    case String.trim(params["name"] || "") do
      "" -> {:error, [name: "Enter a calendar name."]}
      name -> {:ok, name}
    end
  end

  defp required_service_id(params) do
    case String.trim(params["service_id"] || "") do
      "" -> {:error, [service_id: "Enter a feed ID."]}
      service_id -> {:ok, service_id}
    end
  end

  defp weekly_attrs(params) do
    case {parse_date(params["start_date"]), parse_date(params["end_date"])} do
      {{:ok, start_date}, {:ok, end_date}} ->
        ordered_weekly_attrs(params, start_date, end_date)

      {start_date, end_date} ->
        {:error,
         Enum.concat(
           if(start_date == :error, do: [start_date: "Choose a start date."], else: []),
           if(end_date == :error, do: [end_date: "Choose an end date."], else: [])
         )}
    end
  end

  # Civil dates compare chronologically through Date.compare/2; struct ordering
  # would compare the day before the month and misread a year boundary.
  defp ordered_weekly_attrs(params, start_date, end_date) do
    if Date.compare(end_date, start_date) == :lt do
      {:error, [end_date: "The end date must be on or after the start date."]}
    else
      days =
        @weekday_fields
        |> Enum.map(fn field -> {String.to_existing_atom(field), weekday_flag(field, params)} end)
        |> Map.new()

      {:ok, Map.merge(days, %{start_date: start_date, end_date: end_date})}
    end
  end

  defp weekday_flag(field, params), do: if(field in params["weekdays"], do: 1, else: 0)

  defp additions(params) do
    case parse_dates(Enum.join(params["dates"], ",")) do
      {:ok, []} -> {:error, [date_input: "Add at least one service date."]}
      {:ok, dates} -> {:ok, %{dates: dates}}
      :error -> {:error, [date_input: "Choose valid dates."]}
    end
  end

  defp metadata_attrs(params) do
    type =
      case params["service_schedule_type"] do
        "" -> nil
        value -> value
      end

    rating_start = parse_optional_date(params["rating_start_date"])
    rating_end = parse_optional_date(params["rating_end_date"])

    cond do
      rating_start == :error or rating_end == :error ->
        {:error, [rating_start_date: "Choose valid dates for the schedule period."]}

      is_struct(rating_start, Date) and is_struct(rating_end, Date) and
          Date.compare(rating_end, rating_start) == :lt ->
        {:error, [rating_end_date: "The schedule period must end on or after it starts."]}

      true ->
        {:ok,
         %{
           service_schedule_name: Values.presence(params["service_schedule_name"]),
           service_schedule_type: type,
           service_schedule_typicality: String.to_integer(params["service_schedule_typicality"]),
           rating_start_date: rating_start,
           rating_end_date: rating_end,
           rating_description: Values.presence(params["rating_description"])
         }}
    end
  end

  ## Dirty guards and independent actions

  defp guard_or_run(socket, command) do
    if socket.assigns.dirty? do
      {:noreply, assign(socket, pending_action: command, error_message: nil)}
    else
      case socket.assigns.live_action do
        :new ->
          {:noreply, socket}

        :show ->
          run_command(socket, command)
      end
    end
  end

  defp run_command(socket, :duplicate), do: handle_event("duplicate", %{}, socket)

  # Discarding has nothing to run after the draft is reset.
  defp run_command(socket, :discard), do: {:noreply, socket}

  defp run_command(socket, command) do
    review_or_apply(socket, socket.assigns.params, command)
  end

  defp continue_pending(socket) do
    cond do
      socket.assigns.pending_action ->
        command = socket.assigns.pending_action
        socket = assign(socket, :pending_action, nil)

        case socket.assigns.live_action do
          :new -> socket
          :show -> elem(run_command(socket, command), 1)
        end

      socket.assigns.pending_navigation ->
        path = socket.assigns.pending_navigation
        socket = assign(socket, :pending_navigation, nil)
        push_navigate(socket, to: path)

      true ->
        socket
    end
  end

  defp switch_version(socket, version_id) do
    organization_id = socket.assigns.current_organization.id
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(organization_id, version_id) do
      path = version_list_path(socket, version_id)

      if socket.assigns.dirty? do
        {:noreply, assign(socket, pending_navigation: path)}
      else
        {:noreply,
         socket
         |> push_event("gtfs_version_selected", %{version_id: version_id})
         |> push_navigate(to: path)}
      end
    else
      {:noreply, socket}
    end
  end

  ## Errors

  defp reject_write(socket, params, reason, command) do
    if is_struct(reason, Ecto.Changeset) do
      reject_submit(socket, params, form_errors(reason))
    else
      socket
      |> put_params(params, errors: [], clear_messages: false)
      |> put_error(area_for(command), write_error_message(reason, command))
      |> assign_delete_block(reason, command)
      |> assign_date_block(reason, command)
      |> focus_message()
    end
  end

  # Only a refused delete is "blocked": a refused conversion says so in its own words.
  # The callout says what the refusal would, so the plain error line is dropped.
  # The callout names both reference kinds whenever both exist: the delete guard
  # returns only the trip tuple, while the page already loaded the same scoped
  # usage read that counts the closures and resolves their pathways.
  defp assign_delete_block(socket, {:in_use, trip_count, route_ids}, {:delete, _service_id}) do
    assign(socket,
      delete_block: %{
        trip_count: trip_count,
        route_ids: route_ids,
        closure_count: usage_field(socket, :closure_count),
        closure_paths: usage_field(socket, :closure_paths)
      },
      error_message: nil
    )
  end

  defp assign_delete_block(socket, {:closures_in_use, usage}, {:delete, _service_id}) do
    assign(socket,
      delete_block: %{
        trip_count: usage.trip_count,
        route_ids: usage.route_ids,
        closure_count: usage.closure_count,
        closure_paths: usage.closure_paths
      },
      error_message: nil
    )
  end

  defp assign_delete_block(socket, _reason, _command), do: socket

  # The last-native-row refusal belongs beside the date action that tried it, so
  # it is held separately from the deletion block. A conversion that would empty
  # the calendar reaches the same reason from the kind fields, where the date
  # callout would be wrong; that one keeps the plain error line.
  defp assign_date_block(socket, {:closure_reference_lost, usage}, command) do
    if date_change_command?(command) do
      assign(socket, date_block: %{command: command, usage: usage}, error_message: nil)
    else
      socket
    end
  end

  defp assign_date_block(socket, _reason, _command), do: socket

  defp date_change_command?({:remove_exceptions, _service_id, _dates}), do: true
  defp date_change_command?({:put_exceptions, _service_id, _dates, _type}), do: true
  defp date_change_command?(_command), do: false

  defp usage_field(socket, field) do
    Map.get(socket.assigns.usage, field, Map.get(empty_usage(), field))
  end

  defp empty_usage do
    %{
      trip_count: 0,
      route_ids: [],
      routes: [],
      closure_count: 0,
      pathway_ids: [],
      closure_paths: []
    }
  end

  # Each message says what happened and what to do next. Edits stay on the page for
  # every failure that keeps the draft, and the copy says so.
  defp write_error_message(:stale_review, _command) do
    {"This calendar changed in another session. Nothing was saved.",
     "Your edits are still on this page. Reloading shows the latest calendar and drops your edits, so copy anything you want to keep first."}
  end

  defp write_error_message(:forbidden, _command) do
    {"You no longer have permission to change this calendar.",
     "Your edits are still on this page. Ask an organization administrator to restore your access, then save again."}
  end

  defp write_error_message(:not_found, _command) do
    {"This calendar is no longer available in this service version.",
     "It may have been deleted in another session, so your edits can’t be saved. They are still on this page."}
  end

  defp write_error_message(:unavailable, command) do
    {failed_title(command),
     "The database is temporarily unavailable. Your edits are still here. Try again in a moment."}
  end

  defp write_error_message(:invalid_command, _command) do
    "That change is not valid for this calendar."
  end

  defp write_error_message(:reversed_range, _command) do
    "Correct this calendar’s dates first."
  end

  defp write_error_message({:in_use, trips, _routes}, {:delete, _service_id}) do
    "#{Wording.count_noun(trips, "trip")} #{if trips == 1, do: "uses", else: "use"} this calendar, so it can’t be deleted."
  end

  defp write_error_message({:in_use, trips, _routes}, _command) do
    {"#{Wording.count_noun(trips, "trip")} #{if trips == 1, do: "uses", else: "use"} this calendar, so it can’t switch to a weekly schedule.",
     "Move its trips to another calendar first."}
  end

  defp write_error_message({:closures_in_use, _usage}, _command) do
    "Scheduled closures use this calendar, so it can’t be deleted."
  end

  defp write_error_message({:closure_reference_lost, _usage}, _command) do
    {"This change would remove the last date that defines this calendar.",
     "Scheduled closures use it. Change or delete them first."}
  end

  defp write_error_message(_reason, command), do: failed_title(command)

  defp failed_title(:create), do: "The calendar wasn’t created."
  defp failed_title(_command), do: "The calendar wasn’t saved."

  # Domain changesets own field errors; the mapping renames them onto the form
  # fields the editor renders and words each as a sentence that says what to do.
  defp form_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map(fn {field, messages} ->
      field = form_field(field)
      {field, Enum.map(messages, &plain_error(field, &1))}
    end)
    |> Enum.reject(fn {field, _messages} -> field == nil end)
  end

  defp form_field(:service_description), do: :name
  defp form_field(:service_days), do: :weekdays
  defp form_field(:dates), do: :date_input
  defp form_field(field), do: field

  defp plain_error(:name, "has already been taken"),
    do: "Another calendar already has this name. Choose a different name."

  defp plain_error(:name, message) when message in ["can't be blank", "can’t be blank"],
    do: "Enter a calendar name."

  defp plain_error(:service_id, "has already been taken"),
    do: "Another calendar already uses this feed ID. Choose a different one."

  defp plain_error(:service_id, message) when message in ["can't be blank", "can’t be blank"],
    do: "Enter a feed ID."

  defp plain_error(:weekdays, "select at least one service day"),
    do: "Choose at least one service day."

  defp plain_error(:end_date, "must be on or after the start date"),
    do: "The end date must be on or after the start date."

  defp plain_error(:rating_end_date, "must be greater than or equal to rating_start_date"),
    do: "The schedule period must end on or after it starts."

  defp plain_error(:date_input, "add at least one service date"),
    do: "Add at least one service date."

  defp plain_error(_field, message), do: sentence(message)

  defp sentence(message) do
    {first, rest} = message |> String.trim() |> String.split_at(1)
    message = String.upcase(first) <> rest
    if String.ends_with?(message, "."), do: message, else: message <> "."
  end

  defp date_error, do: [date_input: "Choose a valid date."]

  ## Audit

  defp audit_context(socket) do
    %AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      station_stop_id: nil,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end

  ## Input helpers

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp parse_optional_date(value) do
    case parse_date(value) do
      {:ok, date} -> date
      :error -> if Values.blank?(value), do: nil, else: :error
    end
  end

  defp parse_dates(value) when is_binary(value) do
    parts = String.split(value, ",", trim: true)

    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case parse_date(part) do
        {:ok, date} -> {:cont, {:ok, [date | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, dates} -> {:ok, dates |> Enum.uniq() |> Enum.sort(Date)}
      :error -> :error
    end
  end

  defp parse_dates(_value), do: :error

  defp ordered_range(first_date, last_date) do
    if Date.compare(last_date, first_date) == :lt do
      {:error, "The last day off must be on or after the first day off."}
    else
      :ok
    end
  end

  defp date_string(nil), do: ""
  defp date_string(%Date{} = date), do: Date.to_iso8601(date)

  # The stored service ID is authoritative and comes from the loaded rows, never
  # from the browser, so a detail load can never be pointed at another identity.
  defp source_payload_value(source, :service_id) do
    (source.attributes && source.attributes.service_id) ||
      (source.calendar && source.calendar.service_id) ||
      (List.first(source.exceptions) && List.first(source.exceptions).service_id)
  end

  defp empty_periods,
    do: %{periods: [], breaks: [], holidays: [], extra_days: [], removed_days: []}

  ## Paths

  defp list_path(socket), do: list_path_for(socket.assigns.current_gtfs_version.id)

  defp list_path_for(version_id), do: "/gtfs/#{version_id}/calendars"

  defp detail_path(socket, service_id) do
    list_path(socket) <> "/show?service_id=" <> URI.encode_www_form(service_id)
  end

  defp version_list_path(_socket, version_id), do: "/gtfs/#{version_id}/calendars"

  defp page_title(:new), do: "Create calendar"
  defp page_title(_action), do: "Calendar"

  ## Render

  @impl true
  def render(assigns) do
    assigns = assign_view_state(assigns)

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
      <div
        id="calendar-editor"
        phx-hook="CalendarEditor"
        data-dirty={to_string(@dirty?)}
        class="ds-page"
      >
        <Editor.editor_head
          list_path={list_path_for(@current_gtfs_version.id)}
          crumb={crumb(assigns)}
          heading={heading(assigns)}
          badge={if @show?, do: Editor.status(@source)}
          lede={lede(assigns)}
        >
          <:meta :if={@show?}>
            <span :if={unnamed?(@source)}>Imported without a name · </span>{Editor.usage_line(@usage)} · Feed ID
            <code class="font-mono text-strong">{@service_id}</code>
          </:meta>
          <:actions :if={@show?}>
            <.button
              id="calendar-duplicate"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="duplicate"
            >
              <.icon name="hero-document-duplicate" class="size-4" /> Duplicate calendar
            </.button>
            <.button
              id="calendar-delete"
              type="button"
              variant="secondary"
              class="calendar-delete-button min-h-11"
              phx-click="delete"
            >
              <.icon name="hero-trash" class="size-4" /> Delete calendar
            </.button>
          </:actions>
        </Editor.editor_head>

        <div
          id="calendar-offline"
          phx-disconnected={JS.show(to: "#calendar-offline") |> JS.remove_attribute("hidden")}
          phx-connected={JS.hide(to: "#calendar-offline") |> JS.set_attribute({"hidden", ""})}
          hidden
          class="mb-6"
        >
          <.message kind="warning" title="Reconnecting…">
            Changes you already saved are safe. Keep this page open to continue editing.
          </.message>
        </div>

        <Editor.loading :if={@load_state == :loading} />

        <div :if={@load_state == :unavailable} id="calendar-unavailable" class="max-w-[760px]">
          <.message kind="error" title="We couldn’t load this calendar">
            Nothing was changed. Try again to open it.
            <:action>
              <.button id="calendar-retry" type="button" class="min-h-11" phx-click="retry">
                Try again
              </.button>
            </:action>
          </.message>
        </div>

        <div :if={@load_state == :not_found} id="calendar-not-found" class="max-w-[760px]">
          <.message kind="error" title={"This calendar isn’t in #{@current_gtfs_version.name}"}>
            It may have been deleted, or the link may point to a calendar in another version. Open
            the Calendars list to find it.
            <:action>
              <.button
                id="calendar-back-to-list"
                class="min-h-11"
                navigate={list_path_for(@current_gtfs_version.id)}
              >
                Back to calendars
              </.button>
            </:action>
          </.message>
        </div>

        <div :if={@notices?} id="calendar-notices" class="mb-6 grid gap-3">
          <div :if={@zone_fallback?} id="calendar-timezone-fallback">
            <.message kind="warning" title="Today’s date may be off by a day">
              This version’s agency timezone couldn’t be used ({fallback_reason(@zone.fallback_reason)}), so “today” and the ending-soon warnings use the UTC date. Set one valid
              timezone for the agency.
              <:action>
                <.button
                  id="calendar-timezone-link"
                  variant="secondary"
                  class="min-h-11"
                  navigate={"/gtfs/#{@current_gtfs_version.id}/settings/agencies"}
                >
                  Open Agencies
                </.button>
              </:action>
            </.message>
          </div>

          <div :if={@notes != []} id="periods-warnings">
            <.message
              kind="warning"
              title={
                if length(@notes) == 1,
                  do: "1 thing to check",
                  else: "#{length(@notes)} things to check"
              }
            >
              <ul class="mt-1 grid gap-1">
                <li :for={warning <- @notes}>
                  {Editor.warning_line(warning, @kind, Editor.range_label(@source.calendar))}
                </li>
              </ul>
            </.message>
          </div>

          <div :if={@delete_block} id="calendar-delete-blocked">
            <.message
              id="calendar-delete-blocked-message"
              tabindex="-1"
              kind="error"
              title={delete_block_title(@delete_block)}
            >
              <p :if={@delete_block.trip_count > 0} phx-no-format>{Wording.count_noun(@delete_block.trip_count, "trip")}<span :if={@delete_block.route_ids != []}> on <span :for={{route_id, index} <- Enum.with_index(@delete_block.route_ids)}><.link id={"calendar-delete-blocked-route-#{route_id}"} navigate={~p"/gtfs/#{@current_gtfs_version.id}/routes/#{route_id}"} class="font-semibold underline underline-offset-2">{route_id}</.link><span :if={index < length(@delete_block.route_ids) - 1}>, </span></span></span> still {if @delete_block.trip_count == 1, do: "runs", else: "run"} on it. Move them to another calendar first: <strong>Combine calendars</strong> on the Calendars page moves every trip at once, or you can change the calendar on each route’s schedule. Then delete this one.</p>
              <p
                :if={@delete_block.closure_count > 0}
                id="calendar-delete-closures"
                class={[@delete_block.trip_count > 0 && "mt-2"]}
              >
                {@delete_block.closure_count} {closure_usage_phrase(@delete_block.closure_count)} this calendar on {Wording.noun(
                  length(@delete_block.closure_paths),
                  "pathway"
                )}
                <CalendarComponents.pathway_links
                  id="calendar-delete-pathways"
                  paths={@delete_block.closure_paths}
                  version_id={@current_gtfs_version.id}
                  link_class="font-mono text-[13px] font-semibold underline underline-offset-2"
                  text_class="font-mono text-[13px] font-semibold"
                  suffix="."
                />
                Delete {closure_phrase(@delete_block.closure_count)} on the station’s Closures tab first.
              </p>
              <p :if={@delete_block.trip_count > 0} class="mt-2 flex flex-wrap gap-x-5">
                <a
                  href="#calendar-trips-title"
                  class="inline-flex min-h-11 items-center font-[650] underline underline-offset-2"
                >
                  See the routes that use it
                </a>
                <.link
                  navigate={list_path_for(@current_gtfs_version.id)}
                  class="inline-flex min-h-11 items-center font-[650] underline underline-offset-2"
                >
                  Open Calendars
                </.link>
              </p>
            </.message>
          </div>

          <div :if={@live_action == :show and @source.coverage_error} id="calendar-range-error">
            <.message kind="error" title="This calendar’s end date is before its start date.">
              Correct the dates and save. Until then, no service dates can be worked out for it.
            </.message>
          </div>

          <div :if={@message_area == :page and @error_message}>
            <Editor.outcome kind="error" outcome={@error_message} />
          </div>
        </div>

        <div
          :if={@ready?}
          id="calendar-layout"
          class={[
            "grid gap-6",
            @show? && "lg:grid-cols-[minmax(0,1fr)_420px] lg:items-start",
            not @show? && "max-w-[820px]"
          ]}
        >
          <section
            id="calendar-schedule"
            aria-labelledby="calendar-schedule-title"
            class="min-w-0 overflow-clip rounded-card border border-subtle bg-white lg:col-start-1"
          >
            <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 border-b border-subtle bg-canvas px-4 py-4 sm:px-5">
              <div class="min-w-0">
                <h2
                  id="calendar-schedule-title"
                  class="text-lg font-bold leading-snug tracking-[-0.01em] text-strong"
                >
                  {if @params["kind"] == "weekly", do: "Regular schedule", else: "Schedule"}
                </h2>
                <p class="mt-0.5 text-[13px] text-muted">
                  {if @params["kind"] == "weekly",
                    do: "The days of the week this service runs, and the dates it covers.",
                    else: "This calendar runs only on the dates you choose."}
                </p>
              </div>
              <.unsaved_badge :if={@dirty?} id="calendar-unsaved" />
            </div>

            <.form
              for={@form}
              id="calendar-form"
              phx-change="validate"
              phx-submit="submit_form"
              class="px-4 pt-5 sm:px-5"
            >
              <div :if={@message_area == :schedule and @status_message} class="mb-5">
                <Editor.outcome kind="success" outcome={@status_message} />
              </div>
              <div :if={@message_area == :schedule and @error_message} class="mb-5">
                <Editor.outcome kind="error" outcome={@error_message} />
              </div>

              <.form_error_summary
                :if={@rejected?}
                id="calendar-form-errors"
                title={
                  if @live_action == :new,
                    do: "Calendar not created. Fix these fields.",
                    else: "Calendar not saved. Fix these fields."
                }
                failures={failures(assigns)}
              />

              <div class="max-w-[480px]">
                <.input
                  id="calendar-name"
                  field={@form[:name]}
                  type="text"
                  label="Calendar name"
                  value={@params["name"]}
                  errors={form_errors_for(assigns, :name)}
                  autocomplete="off"
                  help={name_help(assigns)}
                />
              </div>

              <Editor.kind_cards
                name={@form[:kind].name}
                kind={@params["kind"]}
                dates_only_disabled={reversed_range?(assigns)}
              />

              <div :if={@params["kind"] == "weekly"} id="calendar-weekly-fields" class="mt-6">
                <Editor.weekday_toggles
                  id="calendar-weekdays"
                  name={@form[:weekdays].name <> "[]"}
                  options={@weekday_options}
                  selected={@params["weekdays"]}
                  presets={@presets}
                  error={field_error(assigns, :weekdays)}
                />

                <div class="mt-5 grid gap-4 sm:max-w-[480px] sm:grid-cols-2">
                  <.input
                    id="calendar-start-date"
                    field={@form[:start_date]}
                    type="date"
                    label="Start date"
                    value={@params["start_date"]}
                    errors={form_errors_for(assigns, :start_date)}
                  />
                  <.input
                    id="calendar-end-date"
                    field={@form[:end_date]}
                    type="date"
                    label="End date"
                    value={@params["end_date"]}
                    errors={form_errors_for(assigns, :end_date)}
                  />
                </div>
                <p class="mt-2 text-[13px] text-muted">
                  {if @live_action == :new,
                    do:
                      "Both dates are included. You can add holidays and breaks after you create the calendar.",
                    else:
                      "Both dates are included. Holidays and breaks go under Days off and extra service."}
                </p>
              </div>

              <div :if={@params["kind"] == "dates_only"} id="calendar-dates-fields" class="mt-6">
                <div :if={@live_action == :new}>
                  <div class="max-w-[220px]">
                    <.input
                      id="calendar-date-input"
                      field={@form[:date_input]}
                      type="date"
                      label="Service date"
                      value={@params["date_input"]}
                      errors={form_errors_for(assigns, :date_input)}
                      help="Pick a date to add it to the list. Repeat for each day the calendar runs."
                    />
                  </div>
                  <ul
                    :if={@params["dates"] != []}
                    id="calendar-draft-dates"
                    aria-label="Service dates to add"
                    class="mt-3 flex flex-wrap gap-2"
                  >
                    <li
                      :for={iso <- @params["dates"]}
                      id={"calendar-draft-date-#{iso}"}
                      class="inline-flex min-h-11 items-center gap-1 rounded-control border border-subtle bg-canvas pl-3 pr-1 text-sm"
                    >
                      <span class="font-semibold text-strong">
                        {Wording.weekday_date_with_year(date_from_iso(iso))}
                      </span>
                      <button
                        type="button"
                        phx-click="remove_draft_date"
                        phx-value-date={iso}
                        aria-label={"Remove #{Wording.date(date_from_iso(iso))}"}
                        class="inline-flex size-11 items-center justify-center rounded-control text-muted hover:bg-white hover:text-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                      >
                        <.icon name="hero-x-mark" class="size-4" />
                      </button>
                    </li>
                  </ul>
                  <p :if={@params["dates"] == []} class="mt-3 text-[13px] text-muted">
                    No dates yet.
                  </p>
                </div>
                <p
                  :if={@live_action == :show}
                  class="rounded-control bg-canvas px-4 py-3 text-sm text-default"
                >
                  This calendar runs only on the dates listed under
                  <strong class="font-semibold text-strong">Service dates</strong>
                  below. Add or remove dates there.
                </p>
              </div>

              <details
                :if={@live_action == :new}
                id="calendar-service-id-details"
                open={form_errors_for(assigns, :service_id) != []}
                phx-mounted={JS.ignore_attributes("open")}
                class="group mt-6"
              >
                <summary class="flex min-h-11 cursor-pointer list-none flex-wrap items-center gap-x-2 text-[13px] text-muted [&::-webkit-details-marker]:hidden">
                  <span phx-no-format>Feed ID <code :if={@params["service_id"] != ""} id="calendar-service-id-preview" class="rounded-badge bg-canvas px-1.5 py-0.5 font-mono text-[13px] text-strong">{@params["service_id"]}</code><span :if={@params["service_id"] == ""} id="calendar-service-id-preview">made from the name</span></span>
                  <span aria-hidden="true">·</span>
                  <span class="font-[650] text-action group-open:hidden">Change ID</span>
                  <span class="hidden font-[650] text-action group-open:inline">Hide ID</span>
                </summary>
                <div class="mt-1 max-w-[320px]">
                  <.input
                    id="calendar-service-id"
                    field={@form[:service_id]}
                    type="text"
                    label="Feed ID"
                    value={@params["service_id"]}
                    errors={form_errors_for(assigns, :service_id)}
                    class="w-full input input-lg font-mono"
                    autocomplete="off"
                    spellcheck="false"
                    help="How this calendar is identified in your exported feed and on trips. Must be unique, and can’t change after you create the calendar."
                  />
                </div>
              </details>

              <details
                id="calendar-more-details"
                open={@details_open?}
                class="group mt-6 border-t border-subtle pt-2"
              >
                <summary
                  id="calendar-more-details-summary"
                  phx-click="toggle_details"
                  class="flex min-h-11 cursor-pointer list-none items-center gap-2 text-sm font-semibold text-strong [&::-webkit-details-marker]:hidden"
                >
                  <.icon
                    name="hero-chevron-right"
                    class="size-4 shrink-0 text-muted transition-transform group-open:rotate-90 motion-reduce:transition-none"
                  />
                  <span>
                    Details for the exported feed
                    <span class="font-normal text-muted">· optional</span>
                  </span>
                </summary>
                <div class="mt-3 grid gap-5 sm:max-w-[520px]">
                  <p class="text-[13px] text-muted">
                    These labels go to <code class="font-mono">calendar_attributes.txt</code>, an optional extension some trip planners read. None of them change which days run.
                  </p>
                  <.input
                    id="calendar-schedule-name"
                    field={@form[:service_schedule_name]}
                    type="text"
                    label="Schedule name"
                    value={@params["service_schedule_name"]}
                    autocomplete="off"
                    help="When this service is in effect, such as “Weekday (no school)” or “Storm (reduced schedule)”."
                  />
                  <div class="max-w-[280px]">
                    <.input
                      id="calendar-schedule-type"
                      field={@form[:service_schedule_type]}
                      type="select"
                      label="Schedule type"
                      options={@schedule_types}
                      value={@params["service_schedule_type"]}
                      help="The kind of day this service is built for. A holiday calendar that runs a Sunday timetable is type Sunday."
                    />
                  </div>
                  <div class="max-w-[360px]">
                    <.input
                      id="calendar-typicality"
                      field={@form[:service_schedule_typicality]}
                      type="select"
                      label="How typical is this service?"
                      options={@typicality_options}
                      value={@params["service_schedule_typicality"]}
                    />
                  </div>
                  <fieldset class="min-w-0">
                    <legend class="text-[13px] font-[650] text-strong">
                      Schedule period (rating)
                    </legend>
                    <p class="mt-0.5 text-[13px] text-muted">
                      The schedule period this service belongs to, such as “Fall 2026”. It is reference information only.
                    </p>
                    <div class="mt-2 grid gap-4 sm:grid-cols-2">
                      <.input
                        id="calendar-rating-start"
                        field={@form[:rating_start_date]}
                        type="date"
                        label="Period start"
                        value={@params["rating_start_date"]}
                        errors={form_errors_for(assigns, :rating_start_date)}
                      />
                      <.input
                        id="calendar-rating-end"
                        field={@form[:rating_end_date]}
                        type="date"
                        label="Period end"
                        value={@params["rating_end_date"]}
                        errors={form_errors_for(assigns, :rating_end_date)}
                      />
                    </div>
                    <div class="mt-4">
                      <.input
                        id="calendar-rating-description"
                        field={@form[:rating_description]}
                        type="text"
                        label="Period name"
                        value={@params["rating_description"]}
                        autocomplete="off"
                      />
                    </div>
                  </fieldset>
                </div>
              </details>

              <Editor.save_bar
                live_action={@live_action}
                dirty?={@dirty?}
                pending?={@pending?}
                note={save_note(assigns)}
                list_path={list_path_for(@current_gtfs_version.id)}
              />
            </.form>
          </section>

          <Editor.preview_card
            :if={@show?}
            month_grid={@month_grid}
            kind={@params["kind"]}
            dirty?={@dirty?}
            today={@today}
          />

          <section
            :if={@show?}
            id="calendar-changes"
            aria-labelledby="calendar-changes-title"
            class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white lg:col-start-1"
          >
            <div class="border-b border-subtle bg-canvas px-4 py-4 sm:px-5">
              <h2
                id="calendar-changes-title"
                class="text-lg font-bold leading-snug tracking-[-0.01em] text-strong"
              >
                {if @kind == :weekly, do: "Days off and extra service", else: "Service dates"}
              </h2>
              <p class="mt-0.5 text-[13px] text-muted">
                {if @kind == :weekly,
                  do:
                    "Holidays, breaks and one-off service. These apply when you confirm them, separately from Save.",
                  else:
                    "This calendar runs only on these dates. Changes apply when you confirm them, separately from Save."}
              </p>
            </div>

            <div class="px-4 py-5 sm:px-5">
              <Editor.service_strip
                calendar={@source.calendar}
                kind={@kind}
                periods={@periods}
                active_dates={@source.active_dates}
                today={@today}
                list_path={list_path_for(@current_gtfs_version.id)}
              />

              <div id="calendar-change-panel" class="grid gap-4 rounded-control bg-canvas p-4">
                <.form
                  :if={@kind == :weekly and not reversed_range?(assigns)}
                  for={@break_form}
                  id="calendar-break-form"
                  phx-change="validate_break"
                  phx-submit="add_break"
                  class="grid gap-2"
                >
                  <h3 class="text-[13px] font-semibold text-strong">Add days off</h3>
                  <div class="flex flex-wrap items-end gap-3">
                    <div class="w-44">
                      <.input
                        id="calendar-break-first"
                        field={@break_form[:first_date]}
                        type="date"
                        label="First day off"
                        value={@break_params["first_date"]}
                      />
                    </div>
                    <div class="w-44">
                      <.input
                        id="calendar-break-last"
                        field={@break_form[:last_date]}
                        type="date"
                        label="Last day off"
                        value={@break_params["last_date"]}
                      />
                    </div>
                    <.button
                      id="calendar-add-break"
                      type="submit"
                      variant="secondary"
                      class="min-h-11"
                    >
                      <.icon name="hero-plus" class="size-4" /> Add days off
                    </.button>
                  </div>
                  <p class="text-[13px] text-muted">
                    Skips only the days this calendar normally runs. For a single day, choose it twice. Three or more service days in a row are shown as a break.
                  </p>
                </.form>

                <.form
                  :if={not reversed_range?(assigns)}
                  for={@exception_form}
                  id="calendar-exception-form"
                  phx-submit="add_dates"
                  class={["grid gap-2", @kind == :weekly && "border-t border-subtle pt-4"]}
                >
                  <h3 class="text-[13px] font-semibold text-strong">
                    {if @kind == :weekly, do: "Add extra service", else: "Add a service date"}
                  </h3>
                  <div class="flex flex-wrap items-end gap-3">
                    <div class="w-44">
                      <.input
                        id="calendar-exception-date"
                        field={@exception_form[:date]}
                        type="date"
                        label={if @kind == :weekly, do: "Date", else: "Service date"}
                      />
                    </div>
                    <.button
                      id="calendar-add-date"
                      type="submit"
                      variant="secondary"
                      class="min-h-11"
                    >
                      <.icon name="hero-plus" class="size-4" />
                      {if @kind == :weekly, do: "Add extra service", else: "Add service date"}
                    </.button>
                  </div>
                  <p class="text-[13px] text-muted">
                    {if @kind == :weekly,
                      do:
                        "Runs trips on a date outside your regular days, such as an event Saturday. A date outside the start and end dates is stored as its own change.",
                      else: "Adds one date this calendar runs. Repeat for each date."}
                  </p>
                </.form>
              </div>

              <div :if={@date_block} class="mt-4">
                <.message
                  id="calendar-date-error"
                  tabindex="-1"
                  kind="error"
                  title={date_block_title(@date_block)}
                >
                  <p id="calendar-date-error-body">{date_block_body(@date_block)}</p>
                  <p id="calendar-date-error-next" class="mt-1">
                    Change or delete {closure_phrase(@date_block.usage.closure_count)} on
                    <CalendarComponents.pathway_links
                      id="calendar-date-error-pathways"
                      paths={@date_block.usage.closure_paths}
                      version_id={@current_gtfs_version.id}
                      link_class="font-mono text-[13px] font-semibold underline underline-offset-2"
                      text_class="font-mono text-[13px] font-semibold"
                    /> first.
                  </p>
                </.message>
              </div>

              <div
                :if={@message_area == :changes and (@status_message || @error_message)}
                class="mt-4"
              >
                <Editor.outcome :if={@status_message} kind="success" outcome={@status_message} />
                <Editor.outcome :if={@error_message} kind="error" outcome={@error_message} />
              </div>

              <div class="mt-5">
                <Editor.change_list
                  kind={@kind}
                  calendar={@source.calendar}
                  periods={@periods}
                  exceptions={@source.exceptions}
                  warnings={@warnings}
                  editable={not reversed_range?(assigns)}
                />
              </div>
            </div>
          </section>

          <Editor.trips_card :if={@show?} usage={@usage} version_id={@current_gtfs_version.id} />
          <CalendarComponents.closures_card
            :if={@show? and @usage.closure_count > 0}
            usage={@usage}
            version_id={@current_gtfs_version.id}
          />
        </div>

        <.confirm_dialog
          id="calendar-review-dialog"
          open={@review_dialog != nil}
          chrome="planner"
          title={@review.title}
          confirm_label={@review.confirm}
          pending_label={@review.pending}
          on_confirm="apply_review"
          on_cancel="cancel_review"
          described_by="calendar-review-dialog-body"
          return_focus_id={review_return_focus(@review_dialog)}
        >
          <div :if={@review_dialog}>
            <p>{@review.lead}</p>
            <ul :if={@review.items != []} class="mt-3 grid list-disc gap-1 pl-5">
              <li :for={item <- @review.items}>{item}</li>
            </ul>
            <div :if={@review.warnings != []} id="calendar-review-warnings" class="mt-3">
              <.message
                kind="warning"
                title={
                  if length(@review.warnings) == 1,
                    do: "1 thing to check",
                    else: "#{length(@review.warnings)} things to check"
                }
              >
                <ul class="mt-1 grid gap-1">
                  <li :for={line <- @review.warnings}>{line}</li>
                </ul>
              </.message>
            </div>
            <div :if={no_service_with_closures?(@review_dialog, @usage)} class="mt-3">
              <.message
                id="calendar-review-closures"
                kind="info"
                title={closure_consequence_title(@usage.closure_count)}
              >
                On {Wording.noun(length(@usage.closure_paths), "pathway")}
                <CalendarComponents.pathway_links
                  id="calendar-review-closures-pathways"
                  paths={@usage.closure_paths}
                  version_id={@current_gtfs_version.id}
                  suffix="."
                /> {closure_consequence(@usage.closure_count)}
              </.message>
            </div>
            <p class="mt-3 font-semibold text-strong">
              This changes {@current_gtfs_version.name}, a published version.
            </p>
          </div>
        </.confirm_dialog>

        <.confirm_dialog
          id="calendar-dirty-dialog"
          open={@pending_navigation != nil or @pending_action != nil}
          chrome="planner"
          title="Discard your unsaved changes?"
          confirm_label="Discard changes"
          cancel_label="Keep editing"
          pending_label="Discarding…"
          on_confirm="discard_changes"
          on_cancel="keep_editing"
          described_by="calendar-dirty-dialog-body"
          return_focus_id="calendar-save"
        >
          <p>{dirty_lead(assigns)}</p>
          <p :if={@pending_action != :discard} class="mt-3">
            To keep them, choose Keep editing and save first.
          </p>
        </.confirm_dialog>
      </div>
    </Layouts.app>
    """
  end

  ## Render helpers

  # What the template branches on, worked out once: which sections exist, which
  # notices the page carries, and the copy of the review dialog when one is open.
  defp assign_view_state(assigns) do
    ready? = assigns.load_state == :ready
    show? = ready? and assigns.live_action == :show
    notes = if show?, do: Editor.actionable(assigns.warnings), else: []
    zone_fallback? = ready? and match?(%{fallback?: true}, assigns.zone)
    page_error? = assigns.message_area == :page and assigns.error_message != nil

    assigns
    |> assign(:ready?, ready?)
    |> assign(:show?, show?)
    |> assign(:notes, notes)
    |> assign(:zone_fallback?, zone_fallback?)
    |> assign(
      :notices?,
      ready? and (zone_fallback? or notes != [] or assigns.delete_block != nil or page_error?)
    )
    |> assign(:review, review_copy(assigns.review_dialog, assigns))
  end

  defp heading(%{load_state: :not_found}), do: "Calendar not found"
  defp heading(%{load_state: state}) when state in [:loading, :unavailable], do: "Calendar"
  defp heading(%{live_action: :new}), do: "New calendar"

  defp heading(%{source: %{attributes: %{service_description: name}}} = assigns)
       when is_binary(name) do
    case String.trim(name) do
      "" -> assigns.service_id || "Untitled calendar"
      trimmed -> trimmed
    end
  end

  defp heading(assigns), do: assigns.service_id || "Untitled calendar"

  defp crumb(%{load_state: :not_found}), do: "Not found"
  defp crumb(%{load_state: state}) when state in [:loading, :unavailable], do: "Calendar"
  defp crumb(assigns), do: heading(assigns)

  defp lede(%{live_action: :new, load_state: :ready}),
    do: "Set when trips run. You can add holidays and breaks after you create it."

  defp lede(%{live_action: :show, load_state: :ready, source: source}), do: Editor.lede(source)
  defp lede(_assigns), do: nil

  defp unnamed?(%{attributes: nil}), do: true
  defp unnamed?(source), do: blank_name?(source)

  defp blank_name?(%{attributes: %{service_description: name}}) when is_binary(name),
    do: String.trim(name) == ""

  defp blank_name?(_source), do: true

  defp name_help(%{live_action: :show, source: source, params: %{"name" => ""}}) do
    if unnamed?(source),
      do:
        "This calendar came in without a name. Add one so your team can recognize it; saving without one is fine.",
      else: name_example()
  end

  defp name_help(_assigns), do: name_example()

  defp name_example, do: "Use a name your team recognizes, such as “Weekday” or “Summer weekday”."

  # Form errors are held as a field-to-messages map so every control renders the
  # message that belongs to it, with the component's own `aria-invalid` and
  # `#{id}-error` association.
  defp field_error(assigns, field), do: assigns.field_errors |> Map.get(field, []) |> List.first()

  defp form_errors_for(assigns, field), do: Map.get(assigns.field_errors, field, [])

  # A stored range that ends before it starts has no service dates, so the commands
  # that read them (conversion, breaks, single-date changes) are not offered until it
  # is corrected.
  defp reversed_range?(%{live_action: :show, source: %{coverage_error: error}}),
    do: error != nil

  defp reversed_range?(_assigns), do: false

  # Where each failing field takes focus, in the order the form shows them.
  @failure_targets [
    name: "calendar-name",
    service_id: "calendar-service-id",
    weekdays: "calendar-weekdays-monday",
    start_date: "calendar-start-date",
    end_date: "calendar-end-date",
    date_input: "calendar-date-input",
    rating_start_date: "calendar-rating-start",
    rating_end_date: "calendar-rating-end"
  ]

  defp failures(assigns) do
    for {field, target} <- @failure_targets,
        message <- [field_error(assigns, field)],
        message != nil,
        do: %{href: "##{target}", msg: message}
  end

  defp fallback_reason(:missing), do: "no agency timezone"
  defp fallback_reason(:invalid), do: "invalid agency timezone"
  defp fallback_reason(:conflicting), do: "conflicting agency timezones"
  defp fallback_reason(_reason), do: "unavailable agency timezone"

  defp save_note(%{live_action: :new} = assigns),
    do:
      "Creates the calendar in #{assigns.current_gtfs_version.name}, a published version. Assign trips from a route’s schedule afterward."

  defp save_note(%{usage: %{trip_count: 0}} = assigns),
    do:
      "No trips use this calendar yet. Changes apply to #{assigns.current_gtfs_version.name}, a published version."

  defp save_note(%{usage: %{trip_count: trips, routes: routes}} = assigns),
    do:
      "Saving updates #{Wording.count_noun(trips, "trip")} on #{Wording.count_noun(length(routes), "route")} in #{assigns.current_gtfs_version.name}, a published version."

  ## Guard copy

  # The reasons the blocked-deletion callout lists and the refusals' count
  # phrases live here, so every sentence that names a reference count pluralizes
  # it in one place instead of leaving a hard-coded plural in the template.
  defp delete_block_title(%{trip_count: trips, closure_count: closures})
       when trips > 0 and closures > 0,
       do: "Trips and closures use this calendar, so it can’t be deleted"

  defp delete_block_title(%{closure_count: closures}) when closures > 0,
    do: "Scheduled closures use this calendar, so it can’t be deleted"

  defp delete_block_title(_block), do: "This calendar is used by trips, so it can’t be deleted"

  defp closure_usage_phrase(1), do: "scheduled closure uses"
  defp closure_usage_phrase(_count), do: "scheduled closures use"

  defp closure_phrase(1), do: "that closure"
  defp closure_phrase(_count), do: "those closures"

  defp closure_consequence_title(count) do
    "#{count} #{CalendarComponents.closure_usage_label(count)}"
  end

  defp closure_consequence(1),
    do: "With no service days, it will not close the pathway on any date."

  defp closure_consequence(_count),
    do: "With no service days, they will not close their pathways on any date."

  # An allowed change that leaves no active dates keeps the native rows closures
  # reference, so it stays allowed with its existing warning. The loaded usage
  # says what that state means for the closures that use the calendar.
  defp no_service_with_closures?(nil, _usage), do: false

  defp no_service_with_closures?(%{warnings: warnings}, usage) do
    usage.closure_count > 0 and Enum.any?(warnings, &match?(%{reason: :no_service}, &1))
  end

  defp date_block_title(%{command: {:remove_exceptions, _service_id, [date]}}) do
    "#{Wording.date(date)} was not removed"
  end

  defp date_block_title(%{command: {:remove_exceptions, _service_id, dates}}) do
    "#{length(dates)} date changes were not removed"
  end

  defp date_block_title(_date_block), do: "The date changes were not removed"

  defp date_block_body(%{usage: %{closure_count: 1}}) do
    "This change would remove the last date that defines this calendar, and 1 scheduled closure uses it."
  end

  defp date_block_body(%{usage: usage}) do
    "This change would remove the last date that defines this calendar, and #{usage.closure_count} scheduled closures use it."
  end

  defp date_from_iso(iso) do
    {:ok, date} = Date.from_iso8601(iso)
    date
  end

  ## Dialog copy

  defp review_return_focus(%{command: {:delete, _}}), do: "calendar-delete"
  defp review_return_focus(%{command: {:convert, _sid, _kind, _attrs}}), do: "calendar-save"

  defp review_return_focus(%{command: {:add_break, _sid, _first, _last}}),
    do: "calendar-add-break"

  defp review_return_focus(%{command: {:remove_exceptions, _sid, _dates}}),
    do: "calendar-add-date"

  defp review_return_focus(%{command: {:put_exceptions, _sid, _dates, _type}}),
    do: "calendar-add-date"

  defp review_return_focus(_dialog), do: "calendar-save"

  # A review says what the change does to this calendar's days, then what stays
  # unchanged, and names the object in the title and the confirm.
  defp review_copy(nil, _assigns) do
    %{
      title: "Review this change",
      confirm: "Save calendar",
      pending: "Saving…",
      lead: nil,
      items: [],
      warnings: []
    }
  end

  defp review_copy(%{command: command, changes: changes, warnings: warnings}, assigns) do
    name = heading(assigns)

    copy = review_copy(command, changes, name, assigns.kind)

    Map.put(
      copy,
      :warnings,
      warnings
      |> Editor.review_warnings()
      |> Enum.map(&Editor.warning_line(&1, review_kind(command, assigns.kind)))
    )
  end

  defp review_kind({:convert, _sid, kind, _attrs}, _current), do: kind
  defp review_kind(_command, current), do: current

  defp review_copy({:delete, _sid}, changes, name, _kind) do
    %{
      title: "Delete #{name}?",
      confirm: "Delete calendar",
      pending: "Deleting…",
      lead: "This removes the calendar and its stored date changes. It can’t be undone.",
      items: [
        "Removes #{Wording.count_noun(changes.active_date_count, "service date")}.",
        "No trips use it, so no trip loses service."
      ]
    }
  end

  defp review_copy({:convert, _sid, :dates_only, _attrs}, changes, name, _kind) do
    %{
      title: "Convert #{name} to chosen dates?",
      confirm: "Convert calendar",
      pending: "Converting…",
      lead:
        "Every date this calendar runs today becomes an individual service date. What runs stays the same; the weekly pattern and its days off are replaced by that list.",
      items: [
        "Stores all #{Wording.count_noun(changes.persisted_date_count, "service date")} as chosen dates.",
        "Removes the weekly days and the date range."
      ]
    }
  end

  defp review_copy({:convert, _sid, :weekly, _attrs}, changes, name, _kind) do
    %{
      title: "Convert #{name} to a weekly schedule?",
      confirm: "Convert calendar",
      pending: "Converting…",
      lead:
        "The calendar will run on the days and dates you chose. Dates you added individually are kept as extra service.",
      items: [
        "Adds a weekly schedule covering #{Wording.count_noun(changes.active_date_count, "service date")}.",
        "Existing date changes are kept."
      ]
    }
  end

  defp review_copy({:add_break, _sid, first, last}, changes, name, _kind) do
    %{
      title: "Skip service #{Editor.date_span(first, last)}?",
      confirm: "Add days off",
      pending: "Saving…",
      lead: "Trips on #{name} won’t run on its service days between these dates.",
      items: [
        skip_line(changes.expected_date_count, changes.removed_date_count),
        "Days outside the range and extra service stay as they are.",
        remaining_line(changes.active_date_count)
      ]
    }
  end

  defp review_copy({:put_exceptions, _sid, [date | _rest] = dates, _type}, changes, name, kind) do
    %{
      title:
        if(length(dates) == 1,
          do: "Add service on #{Wording.weekday_date_with_year(date)}?",
          else: "Add service on #{Wording.count_noun(length(dates), "date")}?"
        ),
      confirm: if(kind == :weekly, do: "Add extra service", else: "Add service date"),
      pending: "Saving…",
      lead:
        "Trips on #{name} will run #{if length(dates) == 1, do: "on this date", else: "on these dates"}.",
      items: [
        "#{Wording.count_noun(changes.active_date_count, "service day")} on this calendar after the change."
      ]
    }
  end

  defp review_copy({:remove_exceptions, _sid, dates}, changes, _name, kind),
    do: remove_copy(dates, changes, kind)

  defp review_copy({:save, _sid, _attrs}, changes, name, _kind) do
    %{
      title: "Save #{name}?",
      confirm: "Save calendar",
      pending: "Saving…",
      lead: "Review the effect before saving.",
      items: [
        "#{Wording.count_noun(changes.active_date_count, "service day")} on this calendar after saving."
      ]
    }
  end

  defp review_copy(_command, changes, _name, _kind) do
    %{
      title: "Review this change",
      confirm: "Save calendar",
      pending: "Saving…",
      lead: "Review the change below before applying it.",
      items: [remaining_line(changes.active_date_count)]
    }
  end

  defp remove_copy([date | _rest] = dates, changes, :weekly) do
    %{
      title:
        if(length(dates) == 1,
          do: "Restore the regular schedule on #{Wording.weekday_date_with_year(date)}?",
          else: "Restore service on #{Wording.count_noun(length(dates), "date")}?"
        ),
      confirm: "Restore service",
      pending: "Saving…",
      lead: "These dates go back to the regular weekly schedule.",
      items: [remaining_line(changes.active_date_count)]
    }
  end

  defp remove_copy([date | _rest] = dates, changes, _kind) do
    %{
      title:
        if(length(dates) == 1,
          do: "Remove #{Wording.weekday_date_with_year(date)}?",
          else: "Remove #{Wording.count_noun(length(dates), "service date")}?"
        ),
      confirm: if(length(dates) == 1, do: "Remove date", else: "Remove dates"),
      pending: "Saving…",
      lead: "These dates are removed from the calendar.",
      items: [remaining_line(changes.active_date_count)]
    }
  end

  defp skip_line(0, _removed),
    do: "This calendar doesn’t run on any of those days, so nothing would change."

  defp skip_line(expected, removed) do
    scope =
      if removed == expected,
        do: "would be skipped",
        else: "(#{Wording.count_noun(removed, "new day")} to skip)"

    "#{Wording.count_noun(expected, "service day")} in the range #{scope}#{if expected >= 3, do: ", so it will appear as a break", else: ""}."
  end

  defp remaining_line(1), do: "1 service day remains on this calendar."
  defp remaining_line(count), do: "#{count} service days remain on this calendar."

  defp dirty_lead(assigns) do
    name = heading(assigns)

    case {assigns.pending_action, assigns.pending_navigation} do
      {:discard, _path} ->
        "Your edits to the schedule for #{name} will be dropped and the saved calendar shown again."

      {nil, path} when is_binary(path) ->
        "You have unsaved changes on this page. Discarding drops them, then opens the page you chose."

      {nil, nil} ->
        ""

      {command, _path} ->
        "You changed the schedule for #{name} but haven’t saved it. Discarding drops those edits, then continues to #{pending_what(command, assigns.kind)}."
    end
  end

  defp pending_what({:add_break, _sid, _first, _last}, _kind), do: "add days off"
  defp pending_what({:put_exceptions, _sid, _dates, _type}, _kind), do: "add this date"
  defp pending_what({:remove_exceptions, _sid, _dates}, :weekly), do: "restore service"
  defp pending_what({:remove_exceptions, _sid, _dates}, _kind), do: "remove the date"
  defp pending_what({:delete, _sid}, _kind), do: "delete the calendar"
  defp pending_what(:duplicate, _kind), do: "duplicate the calendar"
  defp pending_what(_command, _kind), do: "continue"
end
