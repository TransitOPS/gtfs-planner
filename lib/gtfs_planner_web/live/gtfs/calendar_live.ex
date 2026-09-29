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
  only a corrected range can be saved.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.CalendarComponents

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
     |> assign(:usage, %{trip_count: 0, route_ids: [], routes: []})
     |> assign(:kind, :weekly)
     |> assign(:periods, empty_periods())
     |> assign(:preview_month, nil)
     |> assign(:months, [])
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
     |> assign(:pending?, false)
     |> assign(:status_message, nil)
     |> assign(:error_message, nil)
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
         assign(socket, :error_message, "Choose a valid first and last date for the break.")}

      {:error, message} ->
        {:noreply, assign(socket, :error_message, message)}
    end
  end

  def handle_event("add_break", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("add_dates", %{"exception" => submitted}, socket) do
    case parse_date(Map.get(submitted, "date", "")) do
      {:ok, date} ->
        guard_or_run(socket, {:put_exceptions, socket.assigns.service_id, [date], :added})

      :error ->
        {:noreply, assign(socket, :error_message, "Choose a valid date to add.")}
    end
  end

  def handle_event("add_dates", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("remove_date", %{"date" => iso}, socket) do
    case parse_date(iso) do
      {:ok, date} ->
        guard_or_run(socket, {:remove_exceptions, socket.assigns.service_id, [date]})

      :error ->
        {:noreply, assign(socket, :error_message, "That date change could not be read.")}
    end
  end

  @impl true
  def handle_event("remove_break", %{"dates" => dates}, socket) do
    case parse_dates(dates) do
      {:ok, []} ->
        {:noreply,
         assign(socket, :error_message, "That break has no stored date changes to remove.")}

      {:ok, parsed} ->
        guard_or_run(socket, {:remove_exceptions, socket.assigns.service_id, parsed})

      :error ->
        {:noreply, assign(socket, :error_message, "That break could not be read.")}
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
        {:noreply, assign(socket, :error_message, write_error_message(reason))}
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
            {:noreply, after_write(socket, result)}

          {:error, reason} ->
            {:noreply, write_failed(socket, reason)}
        end

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_review", _params, socket) do
    {:noreply, assign(socket, :review_dialog, nil)}
  end

  @impl true
  def handle_event("discard_changes", _params, socket) do
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
    |> assign(:usage, %{trip_count: 0, route_ids: [], routes: []})
    |> assign(:kind, :weekly)
    |> assign(:periods, empty_periods())
    |> assign(:months, [])
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
  end

  # A post-write refresh is a fresh source snapshot, so the retained fingerprint
  # and the dirty baseline both move with it.
  defp refresh_source(socket, message) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.fetch_calendar(organization_id, version_id, socket.assigns.service_id) do
      {:ok, source} ->
        socket
        |> apply_source(source)
        |> assign(:status_message, message)
        |> assign(:preview_month, socket.assigns.preview_month)

      {:error, _reason} ->
        assign(
          socket,
          :error_message,
          "#{message} The calendar could not be reloaded; reload the page to see the stored values."
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

    months =
      for offset <- 0..2 do
        ServiceDates.month_grid(calendar, exceptions, shift_month(first, offset))
      end

    assign(socket, months: months, preview_month: first)
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

  defp preview_step(socket, "next"), do: shift_month(socket.assigns.preview_month, 3)
  defp preview_step(socket, "prev"), do: shift_month(socket.assigns.preview_month, -3)

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

  defp put_params(socket, params, opts) do
    errors = Keyword.get(opts, :errors, [])
    baseline = Keyword.get(opts, :baseline, socket.assigns.baseline)

    socket
    |> assign(:params, params)
    |> assign(:baseline, baseline)
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

  defp reset_draft(socket) do
    params = socket.assigns.baseline || creation_params()

    put_params(socket, params, baseline: params, errors: [])
  end

  ## Saving

  defp save(socket, params) do
    case params_to_command(socket, params) do
      {:ok, :create, attrs} -> create(socket, params, attrs)
      {:ok, command} -> review_or_apply(socket, params, command)
      {:error, errors} -> {:noreply, reject_input(socket, params, errors)}
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
        {:noreply, reject_write(socket, params, reason)}
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
        {:noreply, socket |> assign(:pending?, false) |> reject_write(params, reason)}
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
      {:ok, result} -> {:noreply, after_write(socket, result)}
      {:error, reason} -> {:noreply, write_failed(socket, reason)}
    end
  end

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

  defp after_write(socket, %{action: :deleted}) do
    socket
    |> put_flash(:info, "Deleted #{socket.assigns.service_id}.")
    |> push_navigate(to: list_path(socket))
  end

  defp after_write(socket, %{action: :unchanged}) do
    refresh_source(
      assign(socket, :preview_month, socket.assigns.preview_month),
      "No change was needed."
    )
  end

  defp after_write(socket, result) do
    refresh_source(socket, "Saved. #{result_summary(result)}")
  end

  defp result_summary(%{action: :convert, kind: :dates_only} = result),
    do: "Now stores all #{result.active_date_count} effective service dates as specific dates."

  defp result_summary(%{action: :convert, kind: :weekly}),
    do: "Now runs on a weekly schedule."

  defp result_summary(%{action: :add_break} = result),
    do: "#{result.changed_count} service dates were removed."

  defp result_summary(%{action: :put_exceptions} = result),
    do: "#{result.changed_count} date changes were stored."

  defp result_summary(%{action: :remove_exceptions} = result),
    do: "#{result.changed_count} date changes were removed."

  defp result_summary(%{changed_count: 0}), do: "No change was needed."
  defp result_summary(_result), do: "Saved."

  defp write_failed(socket, reason) do
    socket
    |> assign(error_message: write_error_message(reason), status_message: nil)
    |> assign_delete_block(reason)
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

  defp params_to_command(socket, params) do
    kind = String.to_existing_atom(params["kind"])

    with {:ok, name} <- save_name(socket, params),
         {:ok, metadata} <- metadata_attrs(params),
         {:ok, weekly} <- save_weekly(socket, kind, params) do
      attrs = metadata |> Map.merge(%{name: name, kind: kind}) |> Map.merge(weekly)
      command_for(socket, kind, attrs, params)
    end
  end

  defp save_name(socket, params) do
    if socket.assigns.live_action == :show and params["name"] == socket.assigns.baseline["name"],
      do: {:ok, blank_to_nil(params["name"])},
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
  defp command_for(%{assigns: %{live_action: :new}} = _socket, kind, attrs, params) do
    with {:ok, additions} <- additions_for(kind, params),
         {:ok, service_id} <- required_service_id(params) do
      {:ok, :create, Map.merge(attrs, Map.merge(%{service_id: service_id}, additions))}
    end
  end

  defp command_for(socket, kind, attrs, _params) do
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
      "" -> {:error, [name: "can’t be blank"]}
      name -> {:ok, name}
    end
  end

  defp required_service_id(params) do
    case String.trim(params["service_id"] || "") do
      "" -> {:error, [service_id: "can’t be blank"]}
      service_id -> {:ok, service_id}
    end
  end

  defp weekly_attrs(params) do
    case parse_date(params["start_date"]) do
      :error -> {:error, [start_date: "choose a start date"]}
      {:ok, start_date} -> weekly_end_attrs(params, start_date)
    end
  end

  defp weekly_end_attrs(params, start_date) do
    case parse_date(params["end_date"]) do
      :error ->
        {:error, [end_date: "choose an end date"]}

      {:ok, end_date} ->
        ordered_weekly_attrs(params, start_date, end_date)
    end
  end

  # Civil dates compare chronologically through Date.compare/2; struct ordering
  # would compare the day before the month and misread a year boundary.
  defp ordered_weekly_attrs(params, start_date, end_date) do
    if Date.compare(end_date, start_date) == :lt do
      {:error, [end_date: "must be on or after the start date"]}
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
      {:ok, []} -> {:error, [date_input: "add at least one service date"]}
      {:ok, dates} -> {:ok, %{dates: dates}}
      :error -> {:error, [date_input: "must be a list of valid dates"]}
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
        {:error, [rating_start_date: "choose valid rating dates"]}

      is_struct(rating_start, Date) and is_struct(rating_end, Date) and
          Date.compare(rating_end, rating_start) == :lt ->
        {:error, [rating_end_date: "must be on or after the rating start date"]}

      true ->
        {:ok,
         %{
           service_schedule_name: blank_to_nil(params["service_schedule_name"]),
           service_schedule_type: type,
           service_schedule_typicality: String.to_integer(params["service_schedule_typicality"]),
           rating_start_date: rating_start,
           rating_end_date: rating_end,
           rating_description: blank_to_nil(params["rating_description"])
         }}
    end
  end

  defp blank_to_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      trimmed -> trimmed
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

  defp reject_write(socket, params, reason) do
    if is_struct(reason, Ecto.Changeset) do
      put_params(socket, params, errors: form_errors(reason))
    else
      socket
      |> put_params(params, errors: [], clear_messages: false)
      |> assign(:error_message, write_error_message(reason))
      |> assign_delete_block(reason)
    end
  end

  defp assign_delete_block(socket, {:in_use, trip_count, route_ids}) do
    assign(socket, :delete_block, %{trip_count: trip_count, route_ids: route_ids})
  end

  defp assign_delete_block(socket, _reason), do: socket

  defp write_error_message(:stale_review) do
    "This calendar changed in another session. Your edits are still here; reload to see the stored values, then save again."
  end

  defp write_error_message(:forbidden) do
    "You no longer have permission to change this calendar."
  end

  defp write_error_message(:not_found) do
    "This calendar is no longer available in this service version."
  end

  defp write_error_message(:unavailable) do
    "The database is temporarily unavailable. Your edits are still here."
  end

  defp write_error_message(:invalid_command) do
    "That change is not valid for this calendar."
  end

  defp write_error_message({:in_use, trip_count, _routes}) do
    "#{trip_count} trips use this calendar, so it cannot be deleted."
  end

  defp write_error_message(_reason), do: "The change could not be saved."

  # Domain changesets own field errors; the mapping renames them onto the form
  # fields the editor renders so every message stays associated with its control.
  defp form_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map(fn {field, messages} -> {form_field(field), messages} end)
    |> Enum.reject(fn {field, _messages} -> field == nil end)
  end

  defp form_field(:service_description), do: :name
  defp form_field(:service_days), do: :weekdays
  defp form_field(:dates), do: :date_input
  defp form_field(field), do: field

  defp date_error, do: [date_input: "choose a valid date"]

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
      :error -> if blank?(value), do: nil, else: :error
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

  defp blank?(value), do: String.trim(to_string(value || "")) == ""

  defp ordered_range(first_date, last_date) do
    if Date.compare(last_date, first_date) == :lt do
      {:error, "The break’s last date must be on or after its first date."}
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
      <div id="calendar-editor" phx-hook="CalendarEditor" data-dirty={to_string(@dirty?)} class="mt-6">
        <nav aria-label="Breadcrumb" class="text-sm">
          <.link navigate={list_path_for(@current_gtfs_version.id)} class="link">Calendars</.link>
          <span class="text-base-content/70">{" / "}{breadcrumb_label(assigns)}</span>
        </nav>

        <div
          id="calendar-offline"
          phx-disconnected={JS.show(to: "#calendar-offline") |> JS.remove_attribute("hidden")}
          phx-connected={JS.hide(to: "#calendar-offline") |> JS.set_attribute({"hidden", ""})}
          hidden
          class="mt-3"
        >
          <.callout kind="warning" title="Reconnecting">
            Changes are already saved on the server. Keep this page open to continue editing.
          </.callout>
        </div>

        <div :if={@load_state == :loading} id="calendar-loading" class="mt-6" aria-busy="true">
          <.skeleton rows={4} label="Loading calendar…" />
        </div>

        <div :if={@load_state == :unavailable} id="calendar-unavailable" class="mt-6" role="alert">
          <.callout kind="error" title="This calendar couldn’t be loaded">
            Try again to open it.
            <.button id="calendar-retry" phx-click="retry" variant="secondary" size="sm" class="mt-2">
              Retry
            </.button>
          </.callout>
        </div>

        <div :if={@load_state == :not_found} id="calendar-not-found" class="mt-6">
          <.callout kind="error" title="Calendar not found">
            This calendar does not exist in the selected service version.
            <.button
              id="calendar-back-to-list"
              navigate={list_path_for(@current_gtfs_version.id)}
              variant="secondary"
              size="sm"
              class="mt-2"
            >
              Back to calendars
            </.button>
          </.callout>
        </div>

        <div :if={@load_state == :ready} class="mt-2">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h1 class="text-2xl font-semibold">{heading(assigns)}</h1>
              <p :if={@live_action == :new} class="text-base-content/70">
                Choose when service runs. You can add holidays and breaks next.
              </p>
              <p :if={@live_action == :show} class="text-base-content/70">
                <code class="font-mono">{@service_id}</code>
                <span :if={@source.attributes == nil or blank_name?(@source)}>
                  · Unnamed imported service
                </span>
                <span>{" · "}{kind_label(@kind)}</span>
              </p>
            </div>
            <details :if={@live_action == :show} class="mt-3">
              <summary id="calendar-actions" class="btn btn-sm btn-outline min-h-11 w-fit">
                Calendar actions
              </summary>
              <div class="mt-2 flex flex-wrap gap-3 border border-base-300 bg-base-100 p-3">
                <button
                  id="calendar-duplicate"
                  type="button"
                  class="link text-sm"
                  phx-click="duplicate"
                >
                  Duplicate calendar
                </button>
                <button
                  id="calendar-delete"
                  type="button"
                  class="link text-sm text-error"
                  phx-click="delete"
                >
                  Delete calendar
                </button>
              </div>
            </details>
          </div>

          <div
            :if={@live_action == :show and @source.coverage_error}
            id="calendar-range-error"
            class="mt-4"
          >
            <.callout kind="error" title="This calendar’s end date is before its start date.">
              Correct the dates and save. Until then, no service dates can be worked out for it.
            </.callout>
          </div>

          <div
            :if={(@load_state == :ready and @zone) && @zone.fallback?}
            id="calendar-timezone-fallback"
            class="mt-4"
          >
            <.callout kind="warning" title="Dates use UTC">
              This version’s agency timezone could not be resolved
              ({fallback_reason(@zone.fallback_reason)}), so “today” and the expiry warnings use the UTC
              civil date. Set a single valid agency timezone to avoid a wrong local day.
            </.callout>
          </div>

          <div :if={@live_action == :show} class="mt-4">
            <CalendarComponents.usage_strip
              id="calendar-usage"
              usage={@usage}
              version_id={@current_gtfs_version.id}
            />
          </div>

          <div :if={@delete_block} id="calendar-delete-blocked" class="mt-4">
            <.callout kind="error" title="This calendar is used by trips">
              {@delete_block.trip_count} trips use this calendar <span :if={
                @delete_block.route_ids != []
              }>
                on
                <span :for={
                  {route_id, index} <- Enum.with_index(@delete_block.route_ids)
                }>
                  <span :if={index > 0}>, </span>
                  <.link
                  navigate={~p"/gtfs/#{@current_gtfs_version.id}/routes/#{route_id}"}
                  class="link"
                >
                    {route_id}
                  </.link>
                </span>
              </span>. Reassign those trips before deleting it.
            </.callout>
          </div>

          <p
            id="calendar-status"
            role="status"
            aria-live="polite"
            class="mt-4 text-sm text-base-content/70"
          >
            {@status_message}
          </p>
          <p id="calendar-error" role="alert" class="mt-2 text-sm text-error">{@error_message}</p>

          <.form
            for={@form}
            id="calendar-form"
            phx-change="validate"
            phx-submit="submit_form"
            class="mt-4"
          >
            <section class="border border-base-300 bg-base-100 p-4">
              <h2 class="text-lg font-semibold">Regular schedule</h2>

              <div class="mt-4">
                <.input
                  id="calendar-name"
                  field={@form[:name]}
                  type="text"
                  label="Calendar name"
                  value={@params["name"]}
                  errors={form_errors_for(assigns, :name)}
                  autocomplete="off"
                />
                <p class="text-sm text-base-content/70">
                  Use a name your team knows, such as “School days”.
                </p>
              </div>

              <fieldset class="mt-4">
                <legend class="text-sm font-medium">When does service run?</legend>
                <div class="mt-2 grid gap-2 sm:grid-cols-2">
                  <label class="flex min-h-11 cursor-pointer items-center gap-2 border border-base-300 px-3 py-2 has-[:checked]:border-primary has-[:checked]:bg-primary/5">
                    <input
                      type="radio"
                      id="calendar-kind-weekly"
                      name={@form[:kind].name}
                      value="weekly"
                      checked={@params["kind"] == "weekly"}
                      class="radio radio-sm"
                    />
                    <span class="text-sm font-medium">On a weekly schedule</span>
                  </label>
                  <label class="flex min-h-11 cursor-pointer items-center gap-2 border border-base-300 px-3 py-2 has-[:checked]:border-primary has-[:checked]:bg-primary/5">
                    <input
                      type="radio"
                      id="calendar-kind-dates-only"
                      name={@form[:kind].name}
                      value="dates_only"
                      checked={@params["kind"] == "dates_only"}
                      class="radio radio-sm"
                    />
                    <span class="text-sm font-medium">Only on specific dates</span>
                  </label>
                </div>
              </fieldset>

              <%= if @params["kind"] == "weekly" do %>
                <div class="mt-4">
                  <div class="flex flex-wrap items-center gap-3">
                    <span class="text-sm text-base-content/70">Presets</span>
                    <button
                      :for={{label, _days} <- @presets}
                      id={"calendar-preset-#{label}"}
                      type="button"
                      class="link text-sm"
                      phx-click="preset_days"
                      phx-value-preset={label}
                    >
                      {label}
                    </button>
                  </div>
                  <.checkbox_group
                    id="calendar-weekdays"
                    name={@form[:weekdays].name <> "[]"}
                    label="Service days"
                    options={@weekday_options}
                    selected={@params["weekdays"]}
                    error={field_error(assigns, :weekdays)}
                    help="Days of the week this calendar runs."
                  />
                </div>

                <div class="mt-4 grid gap-4 sm:grid-cols-2">
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
              <% else %>
                <div class="mt-4">
                  <p class="text-sm">
                    Trips run only on specific dates. There is no weekly schedule. For an existing calendar, use the date changes section below to add or remove service dates.
                  </p>
                  <ul
                    :if={@params["dates"] != []}
                    id="calendar-draft-dates"
                    class="mt-2 flex flex-wrap gap-2"
                  >
                    <li
                      :for={iso <- @params["dates"]}
                      id={"calendar-draft-date-#{iso}"}
                      class="inline-flex items-center gap-2 rounded-full border border-control-border px-3 py-1 text-sm"
                    >
                      <span>{CalendarComponents.format_date(date_from_iso(iso))}</span>
                      <button
                        type="button"
                        class="link text-xs"
                        phx-click="remove_draft_date"
                        phx-value-date={iso}
                      >
                        Remove
                      </button>
                    </li>
                  </ul>
                  <div :if={@live_action == :new} class="mt-3 w-44">
                    <.input
                      id="calendar-date-input"
                      field={@form[:date_input]}
                      type="date"
                      label="Service date"
                      value={@params["date_input"]}
                      errors={form_errors_for(assigns, :date_input)}
                      help="Pick a date to add it to the list."
                    />
                  </div>
                </div>
              <% end %>

              <div :if={@live_action == :new} class="mt-4">
                <.input
                  id="calendar-service-id"
                  field={@form[:service_id]}
                  type="text"
                  label="Service ID"
                  value={@params["service_id"]}
                  errors={form_errors_for(assigns, :service_id)}
                  autocomplete="off"
                  help="Suggested from the name. It must be unique and cannot change after creation."
                />
              </div>

              <details id="calendar-more-details" open={@details_open?} class="mt-4">
                <summary
                  id="calendar-more-details-summary"
                  phx-click="toggle_details"
                  class="cursor-pointer text-sm font-medium"
                >
                  More details <span class="text-base-content/70">· optional</span>
                </summary>
                <div class="mt-4 space-y-4">
                  <.input
                    id="calendar-schedule-name"
                    field={@form[:service_schedule_name]}
                    type="text"
                    label="Schedule name"
                    value={@params["service_schedule_name"]}
                  />
                  <.input
                    id="calendar-schedule-type"
                    field={@form[:service_schedule_type]}
                    type="select"
                    label="Schedule type"
                    options={@schedule_types}
                    value={@params["service_schedule_type"]}
                  />
                  <.input
                    id="calendar-typicality"
                    field={@form[:service_schedule_typicality]}
                    type="select"
                    label="How typical is this service?"
                    options={@typicality_options}
                    value={@params["service_schedule_typicality"]}
                  />
                  <div class="grid gap-4 sm:grid-cols-2">
                    <.input
                      id="calendar-rating-start"
                      field={@form[:rating_start_date]}
                      type="date"
                      label="Rating start date"
                      value={@params["rating_start_date"]}
                    />
                    <.input
                      id="calendar-rating-end"
                      field={@form[:rating_end_date]}
                      type="date"
                      label="Rating end date"
                      value={@params["rating_end_date"]}
                    />
                  </div>
                  <.input
                    id="calendar-rating-description"
                    field={@form[:rating_description]}
                    type="text"
                    label="Rating description"
                    value={@params["rating_description"]}
                    help="Optional schedule-period metadata for feed exports; it does not change service dates."
                  />
                </div>
              </details>
            </section>

            <div class="sticky bottom-0 mt-4 flex flex-wrap items-center justify-between gap-3 border border-base-300 bg-base-100 p-4">
              <div>
                <p class="text-sm font-medium">
                  {if @dirty?, do: "Unsaved changes", else: "No unsaved changes"}
                </p>
                <p class="text-sm text-base-content/70">
                  <strong>Changes apply to {@current_gtfs_version.name}, a published version.</strong>
                  {save_impact(assigns)}
                </p>
              </div>
              <div class="flex items-center gap-2">
                <button
                  id="calendar-discard"
                  type="button"
                  class="btn btn-sm btn-outline min-h-11"
                  phx-click="discard_changes"
                  disabled={not @dirty?}
                >
                  {if @live_action == :new, do: "Cancel", else: "Discard changes"}
                </button>
                <button
                  id="calendar-save"
                  type="submit"
                  class="btn btn-sm btn-primary min-h-11"
                  disabled={@pending?}
                  phx-disable-with="Saving…"
                >
                  {if @live_action == :new, do: "Create calendar", else: "Save calendar"}
                </button>
              </div>
            </div>
          </.form>

          <section :if={@live_action == :show} class="mt-6">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 class="text-lg font-semibold">Service periods &amp; changes</h2>
                <p class="text-sm text-base-content/70">
                  Regular service, with breaks and one-off changes applied.
                </p>
              </div>
            </div>

            <CalendarComponents.periods_section
              id="periods"
              periods={@periods}
              exceptions={@source.exceptions}
              timeline_label={"Service periods with #{length(@periods.breaks)} breaks"}
              editable={true}
            />

            <CalendarComponents.warning_list id="periods-warnings" warnings={@warnings} />

            <div :if={@kind == :weekly} class="mt-4 border border-base-300 bg-base-100 p-4">
              <.form
                for={@break_form}
                id="calendar-break-form"
                phx-change="validate_break"
                phx-submit="add_break"
                class="flex flex-wrap items-end gap-3"
              >
                <div class="w-40">
                  <.input
                    id="calendar-break-first"
                    field={@break_form[:first_date]}
                    type="date"
                    label="Break first date"
                    value={@break_params["first_date"]}
                  />
                </div>
                <div class="w-40">
                  <.input
                    id="calendar-break-last"
                    field={@break_form[:last_date]}
                    type="date"
                    label="Break last date"
                    value={@break_params["last_date"]}
                  />
                </div>
                <button id="calendar-add-break" type="submit" class="btn btn-sm btn-outline min-h-11">
                  Add break
                </button>
                <p class="text-sm text-base-content/70">
                  Removes only the expected weekly service dates in the range.
                </p>
              </.form>
            </div>
          </section>

          <section :if={@live_action == :show} class="mt-6">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 class="text-lg font-semibold">Service preview</h2>
                <p id="calendar-preview-intro" class="text-sm text-base-content/70">
                  {if @dirty?,
                    do: "Preview includes your unsaved changes.",
                    else: "Days when trips using this calendar will run."}
                </p>
              </div>
              <div class="flex items-center gap-2">
                <button
                  id="calendar-preview-prev"
                  type="button"
                  class="btn btn-sm btn-outline min-h-11"
                  phx-click="preview_step"
                  phx-value-step="prev"
                  aria-label="Previous three months"
                  title="Previous three months"
                >
                  <span aria-hidden="true">←</span>
                </button>
                <button
                  id="calendar-preview-today"
                  type="button"
                  class="btn btn-sm btn-outline min-h-11"
                  phx-click="preview_step"
                  phx-value-step="today"
                >
                  Today
                </button>
                <button
                  id="calendar-preview-next"
                  type="button"
                  class="btn btn-sm btn-outline min-h-11"
                  phx-click="preview_step"
                  phx-value-step="next"
                  aria-label="Next three months"
                  title="Next three months"
                >
                  <span aria-hidden="true">→</span>
                </button>
              </div>
            </div>

            <CalendarComponents.preview_section
              id="months"
              months={@months}
              preview_label={"Service preview from #{List.first(@months).title}"}
            />

            <p id="preview-date-status" role="status" class="mt-3 text-sm text-base-content/70">
              Use the left and right arrow keys in the preview to move the month window.
            </p>
          </section>

          <section :if={@live_action == :show} class="mt-6">
            <div>
              <h2 class="text-lg font-semibold">Individual date changes</h2>
              <p class="text-sm text-base-content/70">
                Removing a change restores the regular schedule for that date.
              </p>
            </div>

            <div id="calendar-exceptions">
              <CalendarComponents.date_chips
                id="calendar-exception-chips"
                entries={@source.exceptions}
                editable={true}
              />

              <p :if={@source.exceptions == []} class="mt-2 text-sm text-base-content/70">
                No individual date changes.
              </p>
            </div>

            <.form
              for={@exception_form}
              id="calendar-exception-form"
              phx-submit="add_dates"
              class="mt-4 flex flex-wrap items-end gap-3"
            >
              <div class="w-40">
                <.input
                  id="calendar-exception-date"
                  field={@exception_form[:date]}
                  type="date"
                  label="Add service on a date"
                />
              </div>
              <button id="calendar-add-date" type="submit" class="btn btn-sm btn-outline min-h-11">
                Add service day
              </button>
              <p class="text-sm text-base-content/70">
                A date outside the regular range is stored as an explicit change.
              </p>
            </.form>
          </section>
        </div>

        <.confirm_dialog
          id="calendar-review-dialog"
          open={@review_dialog != nil}
          title={dialog_title(@review_dialog)}
          confirm_label={dialog_confirm_label(@review_dialog)}
          pending_label="Saving…"
          on_confirm="apply_review"
          on_cancel="cancel_review"
          described_by="calendar-review-dialog-body"
          confirm_variant="primary"
          return_focus_id={review_return_focus(@review_dialog)}
        >
          <div>
            <p>{dialog_body(assigns)}</p>
            <p class="mt-2 text-sm">
              <strong>This changes {@current_gtfs_version.name}, a published version.</strong>
            </p>
            <ul :if={@review_dialog} class="mt-2 text-sm">
              <li :for={line <- dialog_details(@review_dialog)}>{line}</li>
              <li :for={date <- command_dates(@review_dialog.command)}>Selected date: {date}</li>
            </ul>
            <CalendarComponents.warning_list
              :if={@review_dialog}
              id="calendar-review-warnings"
              warnings={@review_dialog.warnings}
              service_label={@service_id || "Calendar"}
            />
          </div>
        </.confirm_dialog>

        <.confirm_dialog
          id="calendar-dirty-dialog"
          open={@pending_navigation != nil or @pending_action != nil}
          title="Save or discard your schedule changes?"
          confirm_label="Discard and continue"
          cancel_label="Keep editing"
          pending_label="Discarding…"
          on_confirm="discard_changes"
          on_cancel="keep_editing"
          described_by="calendar-dirty-dialog-body"
          confirm_variant="danger"
          return_focus_id="calendar-save"
        >
          <p>
            Your unsaved schedule changes are still on this page. Saving keeps them; discarding and
            continuing drops them and then runs the action you asked for.
          </p>
        </.confirm_dialog>
      </div>
    </Layouts.app>
    """
  end

  ## Render helpers

  defp heading(%{live_action: :new}), do: "Create calendar"

  defp heading(%{source: %{attributes: %{service_description: name}}}) when is_binary(name) do
    case String.trim(name) do
      "" -> "Untitled calendar"
      trimmed -> trimmed
    end
  end

  defp heading(assigns), do: assigns.service_id || "Untitled calendar"

  defp breadcrumb_label(%{live_action: :new}), do: "Create calendar"
  defp breadcrumb_label(assigns), do: heading(assigns)

  defp blank_name?(%{attributes: %{service_description: name}}) when is_binary(name),
    do: String.trim(name) == ""

  defp blank_name?(_source), do: true

  defp kind_label(:weekly), do: "Weekly schedule"
  defp kind_label(_kind), do: "Specific dates"

  # Form errors are held as a field-to-messages map so every control renders the
  # message that belongs to it, with the component's own `aria-invalid` and
  # `#{id}-error` association.
  defp field_error(assigns, field), do: assigns.field_errors |> Map.get(field, []) |> List.first()

  defp form_errors_for(assigns, field), do: Map.get(assigns.field_errors, field, [])

  defp fallback_reason(:missing), do: "no agency timezone"
  defp fallback_reason(:invalid), do: "invalid agency timezone"
  defp fallback_reason(:conflicting), do: "conflicting agency timezones"
  defp fallback_reason(_reason), do: "unavailable agency timezone"

  defp save_impact(%{live_action: :new}),
    do: "Assign trips to this calendar from a route’s schedule after creating it."

  defp save_impact(%{usage: %{trip_count: count}, source: %{attributes: nil}}) when count > 0,
    do: "Saving updates the service days for all #{count} trips using this calendar."

  defp save_impact(%{usage: %{trip_count: 0}}),
    do: "No trips use this calendar yet."

  defp save_impact(%{usage: %{trip_count: count}}),
    do: "Saving updates the service days for all #{count} trips using this calendar."

  defp date_from_iso(iso) do
    {:ok, date} = Date.from_iso8601(iso)
    date
  end

  defp review_return_focus(%{command: {:delete, _}}), do: "calendar-delete"
  defp review_return_focus(%{command: {:convert, _sid, _kind, _attrs}}), do: "calendar-save"

  defp review_return_focus(%{command: {:add_break, _sid, _first, _last}}),
    do: "calendar-add-break"

  defp review_return_focus(%{command: {:remove_exceptions, _sid, _dates}}),
    do: "calendar-add-date"

  defp review_return_focus(%{command: {:put_exceptions, _sid, _dates, _type}}),
    do: "calendar-add-date"

  defp review_return_focus(_dialog), do: "calendar-save"

  defp dialog_title(%{command: {:delete, service_id}}), do: "Delete #{service_id}?"

  defp dialog_title(%{command: {:convert, _sid, :dates_only, _attrs}}),
    do: "Convert to specific dates?"

  defp dialog_title(%{command: {:convert, _sid, :weekly, _attrs}}),
    do: "Convert to a weekly schedule?"

  defp dialog_title(%{command: {:add_break, _sid, _first, _last}}), do: "Add this break?"

  defp dialog_title(%{command: {:put_exceptions, _sid, _dates, _type}}),
    do: "Add this service date?"

  defp dialog_title(%{command: {:remove_exceptions, _sid, _dates}}),
    do: "Remove this service date?"

  defp dialog_title(%{command: {:save, _sid, _attrs}}), do: "Save this calendar?"
  defp dialog_title(_dialog), do: "Review this change"

  defp dialog_confirm_label(%{command: {:delete, _sid}}), do: "Delete calendar"
  defp dialog_confirm_label(%{command: {:convert, _sid, _kind, _attrs}}), do: "Convert calendar"
  defp dialog_confirm_label(%{command: {:add_break, _sid, _first, _last}}), do: "Add break"
  defp dialog_confirm_label(%{command: {:remove_exceptions, _sid, _dates}}), do: "Remove dates"
  defp dialog_confirm_label(%{command: {:put_exceptions, _sid, _dates, _type}}), do: "Add date"
  defp dialog_confirm_label(_dialog), do: "Save calendar"

  defp dialog_body(%{live_action: :show, review_dialog: %{command: {:delete, _sid}}}) do
    "This removes the calendar and its stored date changes. This cannot be undone."
  end

  defp dialog_body(%{review_dialog: %{command: {:convert, _sid, _kind, _attrs}}}) do
    "The preview below shows the exact dates that will be stored."
  end

  defp dialog_body(%{review_dialog: %{command: {:add_break, _sid, _first, _last}}}) do
    "Only the expected weekly service dates in the range are removed; out-of-range additions stay."
  end

  defp dialog_body(%{review_dialog: %{command: {action, _sid, _dates}}})
       when action in [:put_exceptions, :remove_exceptions] do
    "Review the stored date changes below before applying them."
  end

  defp dialog_body(_assigns), do: "Review the change below before applying it."

  defp command_dates({:put_exceptions, _id, dates, _type}), do: dates
  defp command_dates({:remove_exceptions, _id, dates}), do: dates
  defp command_dates({:add_break, _id, first, last}), do: [first, last]
  defp command_dates(_command), do: []

  defp dialog_details(%{changes: %{action: :delete} = changes, warnings: warnings}),
    do: change_lines(changes, warnings) ++ ["0 effective service dates remain."]

  defp dialog_details(%{changes: changes, warnings: warnings}) do
    change_lines(changes, warnings) ++
      ["#{changes.active_date_count} effective service dates remain."] ++
      Enum.map(Map.get(changes, :new_service_dates, []), &"New service on #{&1}.")
  end

  defp change_lines(%{action: :delete, active_date_count: count}, _warnings),
    do: ["Removes #{count} effective service dates."]

  defp change_lines(
         %{action: :convert, kind: :dates_only, persisted_date_count: count},
         _warnings
       ),
       do: [
         "Stores all #{count} effective service dates as specific dates.",
         "Removes the weekly row and the obsolete removals."
       ]

  defp change_lines(%{action: :convert, kind: :weekly, active_date_count: count}, _warnings),
    do: [
      "Adds a weekly schedule covering #{count} effective service dates.",
      "Existing date changes are kept."
    ]

  defp change_lines(%{action: :add_break} = changes, _warnings),
    do: [
      "#{changes.expected_date_count} expected service dates in the range.",
      "#{changes.removed_date_count} would be removed."
    ]

  defp change_lines(%{action: :put_exceptions} = changes, _warnings) do
    [
      count_line(changes.date_count, "date", "dates", "sent"),
      count_line(changes.changed_row_count, "stored value", "stored values", "would change")
    ]
  end

  defp change_lines(%{action: :remove_exceptions} = changes, _warnings) do
    [
      count_line(changes.date_count, "date", "dates", "sent"),
      count_line(changes.removed_row_count, "stored value", "stored values", "would be removed")
    ]
  end

  defp change_lines(changes, _warnings) do
    [
      "#{changes.changed_count} stored values would change.",
      "#{changes.active_date_count} effective service dates remain."
    ]
  end

  defp count_line(1, singular, _plural, rest), do: "1 #{singular} #{rest}."
  defp count_line(count, _singular, plural, rest), do: "#{count} #{plural} #{rest}."
end
