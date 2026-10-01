defmodule GtfsPlannerWeb.Gtfs.AlertEditorLive do
  @moduledoc """
  The alert editor: one LiveView behind both `/alerts/new` and
  `/alerts/:alert_id`, because the editor is one frame and the draft is one row.

  ## URL state, and why the URL carries it

  `?mode=form|assistant` and `?step=<key>` are the editor's whole state before
  anything is saved. A refresh, a shared link and the browser's Back button
  therefore restore the mode and the open question without reading a row, which
  is what makes `/alerts/new` safe to open and abandon: it writes nothing at all
  until the first answer (AC-15, FH-15). Without `?mode` the editor opens in the
  reader's stored preference, and **Make default** stores the mode it is in as
  that preference through `Accounts.update_alert_authoring_mode/2`.

  ## One writer, and one version

  Every write here is `Alerts.create_alert/2`, `Alerts.save_draft/4` or
  `Alerts.delete_alert/3` (INV-1). The audit context is built from the socket's
  trusted assigns - the organization, the version in the URL and the signed-in
  user - so no identity comes from a param (CR-2). The alert's own
  `gtfs_version_id` is checked against the version in the URL before anything
  renders: an alert of another version redirects to this version's list naming
  the version it does belong to, and an alert of another organization - or no
  alert at all - redirects with an error (R1, R6). The editor never reads an
  alert's answers through a version it is not editing, which is also why the
  foreign-version message comes from `Alerts.version_name_for/2`, a read that
  returns a version name and nothing else.

  ## The step sequence

  `steps_for/2` is the only source of the question order (INV-2). It follows the
  step-sequence table in the specification: every sequence starts `urgency` then
  `situation`, adds `mode` when the version runs more than one route type, and
  ends `reason`, `message`, `review`. Before a situation is chosen the sequence
  is just the two questions that decide it, because the rest of the questions
  depend on that answer. The progress row, the Back link and the advance after an
  answer all read this one list.

  ## Autosave, save status and conflicts

  Every question renders inside one `<.form id="alert-form" phx-change="autosave">`
  carrying a hidden `alert[revision]` field, so the row is written through
  `Alerts.save_draft/4` and never through anything else (INV-1). The hidden
  revision is the base revision this editor loaded or last saved; it is read as
  the `expected_revision` argument and never cast, so no param can move an alert
  to a revision of its own (CR-2). That single field is what makes a change
  replayed by form recovery after a reconnect stale rather than silently
  overwriting whatever the other tab wrote (R6, PM-1).

  The save bar reports what actually happened, in the prototype's words:
  `Saving…` while a write is in flight, `Saved` once the server acknowledged it,
  `Not saved.` with **Retry** when it refused. A refused save keeps every typed
  value - the form is rebuilt from the refused changeset, not from the row - and
  a stale save raises `#alert-conflict` with exactly two ways forward,
  **Load latest** and **Save as new alert**. There is no action that overwrites a
  newer revision, because a stale write never overwrites one (R6, AC-16).

  ## Stop targets are selections, never text

  The place, skipped-stops, shared-stop and boarding-alternative questions
  answer with identities, not with what an editor typed. Each combobox is a
  `LiveSelect` whose options come from `Alerts.search_stops/3` scoped to the
  alert's own version, and every identity that reaches a handler is re-read
  through `Alerts.stops_by_id/2` before it is stored: a UUID of another version
  is simply not there, so a forged event saves nothing (R1, R7, CR-4).

  Search text and stored identity are separate values, which is the whole of
  R7. Typing a name and moving on stores nothing, because only a selection
  carries an identity; typing over a chosen label clears the identity rather
  than leaving the old stop attached to new text. `live_select_change` carries
  only the text, so the label a stored stop renders is compared against what was
  typed and the identity is dropped when they differ.

  ## Departures are schedule rows, never typed names

  The cancelled-departures question names the trips the alert cancels and the
  service date each one runs on, because a trip repeats across its service
  dates and a selector without the date matches every one of them. The dates
  are chosen here rather than in a timing step: `steps_for/2` puts
  `departures` - with no `timing` - between `routes` and `reason` for
  `cancelled_trips`, and `Recurrence.date_range/1` reads the alert's own
  service dates.

  The list is `Alerts.departures_on/4` over the alert's own version, so it
  offers only the trips whose service is active on the date being listed, with
  the direction the alert stores narrowing it and a clock past 24:00 saying so.
  Every trip that reaches the row is one this list offered for that date and a
  route the alert names, so a hand-made event attaches nothing (R1, CR-4). The
  writes go through `Alerts.save_draft/4` like every other answer (INV-1).

  ## What this frame does not do

  It carries no publication state and no publication action: saving an alert
  never publishes one in this package, so Live, Scheduled, Ended, End and feed
  copy is absent by construction (R2, CR-1). The question bodies belong to the
  steps that own them; this step builds the frame they render inside, creation on
  the first answer, the version check, the preference, the autosave form with its
  save status and conflict banner, and **Delete alert**. The assistant mode
  renders a placeholder region its own step fills.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.AlertComponents,
    only: [
      alternative_question: 1,
      change_question: 1,
      conflict_banner: 1,
      departures_question: 1,
      direction_question: 1,
      mode_control: 1,
      mode_question: 1,
      message_fields: 1,
      place_question: 1,
      progress: 1,
      question_card: 1,
      rider_preview: 1,
      routes_question: 1,
      save_bar: 1,
      shared_question: 1,
      situation_question: 1,
      stops_question: 1,
      urgency_question: 1
    ]

  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1]

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Completion
  alias GtfsPlanner.Alerts.Listing
  alias GtfsPlanner.Alerts.Recurrence
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlannerWeb.Gtfs.AlertComponents
  alias LiveSelect.Component, as: LiveSelectComponent

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @modes [:form, :assistant]

  # The two single-value stop searches this editor renders, keyed by the
  # LiveSelect component's own id. A `live_select_change` naming any other id is
  # refused, so a hand-made event cannot search this version's stops through a
  # control that does not exist.
  @stop_searches %{"alert-place-stop" => :place, "alert-boarding-stop" => :alternative}
  @stop_search_kinds Map.new(@stop_searches, fn {id, kind} -> {kind, id} end)

  # The question each step asks, in the reader's words. The step *order* is
  # `steps_for/2`; this is only the wording, keyed by the same URL step keys so a
  # step cannot render another step's question.
  @questions %{
    urgency: "When are riders affected?",
    situation: "What is happening?",
    mode: "Which service is affected?",
    change: "What kind of service change?",
    routes: "Which routes are affected?",
    direction: "Which direction is affected?",
    place: "Which stop or station?",
    stops: "Which stops will buses skip?",
    shared: "Are other routes affected at these stops?",
    alternative: "Where should riders board instead?",
    departures: "Which departures will not run?",
    timing: "When will service change?",
    reason: "Why is this happening?",
    message: "Check the message for riders",
    review: "Review alert"
  }

  # The short names the progress row shows. A reader scans for "Timing" and
  # "Message", not for the URL's `urgency` and `message`.
  @step_labels %{
    urgency: "Timing",
    situation: "Situation",
    mode: "Mode",
    change: "Change",
    routes: "Routes",
    direction: "Direction",
    place: "Place",
    stops: "Stops",
    shared: "Shared",
    alternative: "Alternative",
    departures: "Departures",
    timing: "Times",
    reason: "Reason",
    message: "Message",
    review: "Review"
  }

  # The middle of each situation's sequence, exactly as the specification's
  # step-sequence table gives it (spec 4.3). `shared` is marked conditional here
  # because it appears only when a chosen stop is served by a route the alert
  # does not name; `steps_for/2` inserts it under that condition alone.
  @middle_steps %{
    delay: [:routes, :direction, :timing],
    detour: [:routes, :stops, {:shared, :conditional}, :alternative, :timing],
    stop_moved: [:place, :routes, {:shared, :conditional}, :alternative, :timing],
    stop_closed: [:place, :routes, {:shared, :conditional}, :alternative, :timing],
    accessibility: [:place, :routes, :alternative, :timing],
    cancelled_trips: [:routes, :departures],
    suspension: [:routes, :timing],
    service_change: [:change, :routes, :timing]
  }

  @impl true
  def mount(params, _session, socket) do
    mode = preferred_mode(socket)

    {:ok,
     socket
     |> assign(:page_title, "New alert")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:alert_id, params["alert_id"])
     |> assign(:alert, nil)
     |> assign(:preview, empty_preview())
     |> assign(:load_state, :loading)
     |> assign(:mode, mode)
     |> assign(:preferred, mode)
     |> assign(:step, :urgency)
     |> assign(:steps, [])
     |> assign(:flags, %{multimodal?: false, shared_routes?: false})
     |> assign(:delete_open?, false)
     |> assign(:save_state, :idle)
     |> assign(:conflict, nil)
     |> assign(:pending_attrs, nil)
     |> assign(:route_query, "")
     |> assign(:route_options, [])
     |> assign(:route_error, nil)
     |> assign(:place_field, stop_field(nil, :place))
     |> assign(:boarding_field, stop_field(nil, :alternative))
     |> assign(:route_stop_options, [])
     |> assign(:shared_routes, [])
     |> assign(:stop_error, nil)
     |> assign(:stretch_ends, %{})
     |> assign(:directions_open?, false)
     |> assign(:mode_route_types, [])
     |> assign(:directions, [])
     |> assign(:departure_dates, [])
     |> assign(:departure_routes?, false)
     |> assign(:departure_error, nil)
     |> assign(:added_dates, [])
     |> assign(:chosen_date, nil)
     |> assign(:service_date_form, service_date_form(nil))
     |> assign(:form, draft_form(%Alert{}))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_editor(socket, params)}
  end

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket) when is_binary(mode) do
    case Enum.find(@modes, &(Atom.to_string(&1) == mode)) do
      nil ->
        {:noreply, socket}

      mode ->
        # Switching modes keeps every answer: both modes read and write the same
        # row, so this only changes what the URL says.
        {:noreply, push_patch(socket, to: editor_path(socket, mode: mode))}
    end
  end

  def handle_event("make_default_mode", _params, socket) do
    case Accounts.update_alert_authoring_mode(socket.assigns.current_user, socket.assigns.mode) do
      {:ok, user} ->
        {:noreply, assign(socket, current_user: user, preferred: socket.assigns.mode)}

      # The stored mode is one of the two values this control already offers, so a
      # refusal means the preference changed under this editor. The editor keeps
      # working in the mode it is in and simply does not claim the link is now the
      # default.
      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  def handle_event("open_delete", _params, socket) do
    {:noreply, assign(socket, :delete_open?, true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_open?, false)}
  end

  def handle_event("confirm_delete", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, assign(socket, :delete_open?, false)}

      alert ->
        {:noreply, delete_alert(socket, alert)}
    end
  end

  # The first answer creates the draft. Creating on the answer rather than on
  # arrival is what keeps `/alerts/new` free of rows an editor abandoned before
  # saying anything (AC-15, FH-15), and navigating rather than patching means the
  # URL after that answer is the saved row's own URL.
  def handle_event("choose_urgency", %{"urgency" => urgency}, socket)
      when is_binary(urgency) do
    case socket.assigns.alert do
      nil -> create_and_advance(socket, urgency)
      alert -> answer_and_advance(socket, :urgency, alert, %{"urgency" => urgency})
    end
  end

  # Every self-contained choice is the same two steps: write the answer through
  # `Alerts.save_draft/4` (INV-1) and patch to the next question `steps_for/2`
  # puts after this one (INV-2). The values arrive as `phx-value-*` on the card
  # the reader pressed, so a card names its own answer and nothing here reads a
  # field the reader could have typed.
  def handle_event("choose_situation", %{"situation" => situation}, socket)
      when is_binary(situation) do
    answer_and_advance(socket, :situation, %{"situation" => situation})
  end

  def handle_event("choose_change", %{"kind" => kind}, socket) when is_binary(kind) do
    answer_and_advance(socket, :change, %{"service_change_kind" => kind})
  end

  def handle_event("choose_mode", %{"route_type" => route_type}, socket)
      when is_binary(route_type) do
    case parse_choice(route_type) do
      :error ->
        {:noreply, socket}

      route_type ->
        answer_and_advance(socket, :mode, %{"scope" => %{"mode_route_type" => route_type}})
    end
  end

  # "Both directions" stores no direction at all, which is how the scope answer
  # says "every direction"; the other cards store their own number.
  def handle_event("choose_direction", %{"direction" => direction}, socket)
      when is_binary(direction) do
    case parse_choice(direction) do
      :error ->
        {:noreply, socket}

      direction_id ->
        answer_and_advance(socket, :direction, %{"scope" => %{"direction_id" => direction_id}})
    end
  end

  # A route multi-select is not self-contained, so its choices do not advance on a
  # click: each toggle is written at once, which is what keeps Back lossless, and
  # Continue is the explicit action that moves on (AC-17).
  def handle_event("search_routes", params, socket) when is_map(params) do
    case search_query(params) do
      nil ->
        {:noreply, socket}

      query ->
        {:noreply,
         socket
         |> assign(:route_query, query)
         |> assign(:route_options, Alerts.search_routes(audit_context(socket), query))}
    end
  end

  def handle_event("toggle_route", %{"id" => id}, socket) when is_binary(id) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        chosen = scope(alert).route_ids || []

        ids =
          if id in chosen, do: List.delete(chosen, id), else: chosen ++ [id]

        save(socket, alert, %{"scope" => %{"shape" => "routes", "route_ids" => ids}})
    end
  end

  # The whole system is one choice, so it saves and advances like the others; the
  # multi-select below it is what the reader gets when the alert is about routes
  # instead.
  def handle_event("choose_system_scope", _params, socket) do
    answer_and_advance(socket, :routes, %{"scope" => %{"shape" => "system", "route_ids" => []}})
  end

  def handle_event("continue_routes", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        if scope(alert).shape == :system or present?(scope(alert).route_ids) do
          {:noreply, advance_without_writing(socket, alert, :routes)}
        else
          # Nothing is written and nothing moves: the question stays open with the
          # reason on it, so the reader can answer rather than guess.
          {:noreply,
           assign(socket, :route_error, "Choose at least one route, or the whole system.")}
        end
    end
  end

  # The autosave path. Every keystroke that settles reaches here through the
  # form's `phx-change`, carrying the whole form and this editor's base
  # revision in the hidden field. Nothing else writes this row (INV-1).
  # A `LiveSelect` selection is not an event of its own: it writes the chosen
  # value into a hidden input that belongs to this form, so it arrives here with
  # the rest of the change. The field it writes is named for the question rather
  # than for the answer, because the identity still has to be checked against the
  # version before it is stored (R7, R1).
  def handle_event("autosave", %{"place" => %{"stop_id" => id}} = params, socket)
      when is_binary(id) do
    case socket.assigns.alert do
      nil -> {:noreply, socket}
      alert -> pick_place(socket, alert, id, params)
    end
  end

  def handle_event("autosave", %{"alternative" => %{"stop_id" => id}} = params, socket)
      when is_binary(id) do
    case socket.assigns.alert do
      nil -> {:noreply, socket}
      alert -> pick_alternative(socket, alert, id, params)
    end
  end

  # The service date is a form field inside this same autosave form, so a chosen
  # date arrives as this question's own answer rather than as an event of its
  # own. It is only the date the editor is looking at: **Add date** is what puts
  # it in the list, so typing a date never answers the question by itself and
  # nothing is written for it here.
  def handle_event("autosave", %{"service_date" => %{"date" => value}}, socket)
      when is_binary(value) do
    {:noreply,
     socket
     |> assign(:chosen_date, parse_date(value))
     |> assign(:service_date_form, service_date_form(value))}
  end

  def handle_event("autosave", %{"alert" => params}, socket) when is_map(params) do
    case socket.assigns.alert do
      # Nothing has been answered yet, so there is no row to save. The first
      # answer creates it (AC-15); autosave has nothing to write before that.
      nil ->
        {:noreply, socket}

      alert ->
        # A change carrying nothing but the base revision is the route search
        # losing focus, not an answer. Writing it would move the row's revision
        # for no change and hand the next write a base nobody typed at.
        if castable(params) == %{} do
          {:noreply, socket}
        else
          save(socket, alert, params)
        end
    end
  end

  # Retry re-sends the params the last save carried. The typed values are still
  # in `@pending_attrs`, so this is the same write attempted again rather than a
  # fresh read of the row - which is what makes it a retry of *this* edit.
  def handle_event("retry_save", _params, socket) do
    case {socket.assigns.alert, socket.assigns.pending_attrs} do
      {alert, params} when not is_nil(alert) and is_map(params) ->
        save(socket, alert, params)

      _other ->
        {:noreply, socket}
    end
  end

  # Taking the other side of a conflict: reload the row and show what it holds
  # now. The typed values this editor had are dropped here, and only here -
  # losing them is the point of choosing the newer draft.
  def handle_event("load_latest", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        case Alerts.get_alert(audit_context(socket), alert.id) do
          {:ok, current} ->
            {:noreply,
             socket
             |> assign(:alert, current)
             |> assign(:conflict, nil)
             |> assign(:pending_attrs, nil)
             |> assign(:form, draft_form(current))
             |> assign(:save_state, :saved)
             |> rebuild(current)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, write_error_message(reason))}
        end
    end
  end

  # Keeping this side of a conflict: the values this editor holds become a
  # separate alert, so neither draft is lost. The conflict row is left exactly
  # as the other editor saved it.
  def handle_event("save_as_new", _params, socket) do
    case socket.assigns.pending_attrs do
      params when is_map(params) ->
        case Alerts.create_alert(audit_context(socket), castable(params)) do
          {:ok, created} ->
            {:noreply,
             socket
             |> assign(:conflict, nil)
             |> assign(:pending_attrs, nil)
             |> push_navigate(to: saved_path(socket, created, socket.assigns.step))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, write_error_message(reason))}
        end

      nil ->
        {:noreply, socket}
    end
  end

  # The prototype's Save and close: write what is typed, then return to the
  # list. A refused or stale write stays on the page rather than leaving, so
  # nothing typed can be dropped by walking away from a failed save.
  def handle_event("save_and_close", params, socket) do
    # A submit carries the whole form, so a value typed within the debounce
    # window is written rather than dropped; a click carries none, and the
    # pending autosave params are already the same values.
    socket =
      case params do
        %{"alert" => alert_params} when is_map(alert_params) ->
          assign(socket, :pending_attrs, alert_params)

        _other ->
          socket
      end

    case write_pending(socket) do
      {:ok, socket} -> {:noreply, leave_editor(socket)}
      {:refused, socket} -> {:noreply, socket}
    end
  end

  # -- Stop questions ----------------------------------------------------

  # A `LiveSelect` pushes this on every keystroke. It carries the text the
  # editor typed and the component's own id, and nothing else: a selection
  # arrives through the form instead, because `LiveSelect` writes its selection
  # into a hidden input that belongs to the form (R7).
  #
  # An id this editor does not render is refused, so a hand-made event cannot
  # search this version's stops through a control that is not on the page.
  def handle_event("live_select_change", %{"id" => id} = params, socket) when is_binary(id) do
    case Map.fetch(@stop_searches, id) do
      {:ok, kind} -> {:noreply, search_stop_options(socket, kind, params["text"])}
      :error -> {:noreply, socket}
    end
  end

  # **Write directions instead** is the alternative to choosing a stop, so it
  # clears the chosen stop and opens the field the answer is typed into. The
  # directions themselves arrive through the form, on the same 450 ms debounce
  # every other typed answer uses.
  def handle_event("write_directions", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      _alert ->
        case write_stop(socket, %{"scope" => %{"alternative_stop_id" => nil}}) do
          {:noreply, socket} -> {:noreply, assign(socket, :directions_open?, true)}
          other -> other
        end
    end
  end

  # A skipped stop is one toggle and one write, which is what keeps Back
  # lossless: the list is on the row before Continue is pressed.
  def handle_event("toggle_stop", %{"id" => id}, socket) when is_binary(id) do
    alert = socket.assigns.alert

    with %{} = alert <- alert,
         %{^id => _stop} <- Alerts.stops_by_id(audit_context(socket), [id]) do
      chosen = scope(alert).stop_ids || []
      ids = if id in chosen, do: List.delete(chosen, id), else: chosen ++ [id]

      write_stop(socket, %{"scope" => %{"shape" => "route_stops", "stop_ids" => ids}})
    else
      _not_an_alert_or_not_in_scope -> {:noreply, socket}
    end
  end

  # A stretch is the two ends the editor names, and the stops between them are
  # what the detour skips, so the resolved list is stored beside the pair. Each
  # end is chosen in its own select, so one of them is reported by the event and
  # the other is the half the editor already chose; a half pair says so rather
  # than saving something the editor did not name.
  #
  # Both ends are re-read through the scoped lookup, and the slice is taken from
  # the route's own stop order, so a pair of UUIDs from another version resolves
  # nothing at all.
  def handle_event("select_stretch", %{"which" => which, "value" => value}, socket)
      when is_binary(which) do
    alert = socket.assigns.alert
    ends = Map.put(socket.assigns.stretch_ends, which, value)
    stops = stretch_stops(socket, ends["from"], ends["to"], socket.assigns.route_stop_options)

    case {alert, stops} do
      {nil, _stops} ->
        {:noreply, socket}

      {_alert, nil} ->
        {:noreply,
         socket
         |> assign(:stretch_ends, ends)
         |> assign(:stop_error, "Choose both ends of the stretch.")}

      {_alert, stops} ->
        {from_id, to_id} = {List.first(stops), List.last(stops)}

        case write_stop(socket, %{
               "scope" => %{
                 "shape" => "route_stops",
                 "stop_ids" => stops,
                 "stretch_from_stop_id" => from_id,
                 "stretch_to_stop_id" => to_id
               }
             }) do
          {:noreply, socket} ->
            {:noreply, socket |> assign(:stretch_ends, %{}) |> assign(:stop_error, nil)}

          other ->
            other
        end
    end
  end

  # "All stops still served" is not a detour, so it is answered by changing the
  # situation rather than by answering the question the situation opened.
  def handle_event("all_stops_served", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        case Alerts.save_draft(audit_context(socket), alert.id, alert.revision, %{
               "situation" => "delay",
               "scope" => %{
                 "stop_ids" => [],
                 "stretch_from_stop_id" => nil,
                 "stretch_to_stop_id" => nil
               }
             }) do
          {:ok, saved} ->
            {:noreply,
             socket
             |> assign(:alert, saved)
             |> assign(:form, draft_form(saved))
             |> assign(:save_state, :saved)
             |> rebuild(saved)
             |> push_patch(to: saved_path(socket, saved, advance(saved, :routes, socket)))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, write_error_message(reason))}
        end
    end
  end

  # The shared-stop answer is one question about the routes the alert does not
  # name. "Yes" stores the pairs that make those routes affected at the same
  # stops, so the target is the stops rather than the routes, which is what the
  # alert means; "no" stores that they are not (AC-18).
  def handle_event("choose_shared", %{"answer" => "yes"}, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        case shared_pairs(socket, alert) do
          [] ->
            {:noreply, socket}

          pairs ->
            answer_and_advance(socket, :shared, alert, %{
              "scope" => %{"all_routes_at_stops" => true, "route_stop_pairs" => pairs}
            })
        end
    end
  end

  def handle_event("choose_shared", %{"answer" => "no"}, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        answer_and_advance(socket, :shared, alert, %{"scope" => %{"all_routes_at_stops" => false}})
    end
  end

  # The skipped-stop list is a multi-select, so it is written as it is chosen and
  # Continue is the explicit action that moves on. Nothing chosen says so inline
  # rather than advancing over an answer that was never stored.
  def handle_event("continue_stops", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        if present?(scope(alert).stop_ids) do
          {:noreply, advance_without_writing(socket, alert, :stops)}
        else
          {:noreply, assign(socket, :stop_error, "Choose at least one stop this detour skips.")}
        end
    end
  end

  # A moved stop and an accessibility alert have to say where riders go
  # instead, so this question refuses to advance until it has a stop or written
  # directions. A closed stop and a detour may leave it as it is (AC-18).
  def handle_event("continue_alternative", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        if alternative_required?(alert) and not alternative_answered?(alert) do
          {:noreply,
           assign(socket, :stop_error, "Choose a stop to board at, or write directions instead.")}
        else
          {:noreply, advance_without_writing(socket, alert, :alternative)}
        end
    end
  end

  # -- Departures --------------------------------------------------------

  # **Add date** is one date at a time, because each date has its own checklist:
  # the trips running on a Monday are not the trips running on the Saturday
  # after it (AC-19). The date the editor typed is the one this adds, and a
  # date already in the list is added once.
  def handle_event("add_service_date", _params, socket) do
    case socket.assigns.chosen_date do
      nil ->
        {:noreply, assign(socket, :departure_error, "Choose a date to add.")}

      date ->
        {:noreply,
         socket
         |> assign(:added_dates, Enum.uniq(socket.assigns.added_dates ++ [date]))
         |> assign(:departure_error, nil)
         |> load_departure_dates()}
    end
  end

  # Removing a date takes its pairs with it, because a trip cancelled on a date
  # the alert no longer names is a trip the alert still claims. A date that held
  # no selection is only removed from the working list, and writes nothing.
  def handle_event("remove_service_date", %{"date" => value}, socket) when is_binary(value) do
    with %Date{} = date <- parse_date(value) do
      socket = assign(socket, :added_dates, List.delete(socket.assigns.added_dates, date))

      case socket.assigns.alert do
        nil -> {:noreply, load_departure_dates(socket)}
        alert -> drop_date_pairs(socket, alert, date)
      end
    else
      _not_a_date -> {:noreply, socket}
    end
  end

  # A departure is one checkbox and one write, which is what keeps Back lossless:
  # the pair is on the row before Continue is pressed (AC-19).
  #
  # The pair is only stored when the schedule really offers that trip on that
  # date for a route the alert names, so a hand-made event cannot attach a trip
  # of another version, a trip that does not run, or a trip of a route this
  # alert does not name (R1, CR-4, INV-1).
  def handle_event("toggle_departure", %{"trip_id" => trip_id, "date" => value}, socket)
      when is_binary(trip_id) and is_binary(value) do
    alert = socket.assigns.alert

    with %{} = alert <- alert,
         %Date{} = date <- parse_date(value),
         true <- departure_offered?(socket, alert, trip_id, date) do
      chosen = scope(alert).trips
      pair = {trip_id, date}

      trips =
        if Enum.any?(chosen, &({&1.trip_id, &1.service_date} == pair)) do
          Enum.reject(chosen, &({&1.trip_id, &1.service_date} == pair))
        else
          chosen ++ [%{"trip_id" => trip_id, "service_date" => date}]
        end

      write_stop(socket, %{"scope" => %{"shape" => "trips", "trips" => trip_params(trips)}})
    else
      _not_offered_on_that_date -> {:noreply, socket}
    end
  end

  # The departure list is a multi-select, so it is written as it is chosen and
  # Continue is the explicit action that moves on. Nothing chosen says so inline
  # rather than advancing over an answer that was never stored.
  def handle_event("continue_departures", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        if present?(scope(alert).trips) do
          {:noreply, advance_without_writing(socket, alert, :departures)}
        else
          {:noreply,
           assign(socket, :departure_error, "Choose at least one departure that will not run.")}
        end
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # R7, and the failure EV-16 exists to reject: a label the editor then types
  # over is no longer the stop it named. The identity is dropped here rather
  # than left attached to new text, and the combobox is told the selection is
  # gone so it cannot put the label back.
  defp search_stop_options(socket, kind, text) do
    text = if is_binary(text), do: text, else: ""

    socket
    |> clear_edited_label(kind, text)
    |> send_stop_options(kind, text)
  end

  defp send_stop_options(socket, kind, text) do
    send_update(LiveSelectComponent,
      id: Map.fetch!(@stop_search_kinds, kind),
      options: socket |> stop_search(kind, text) |> Enum.map(&stop_option/1)
    )

    socket
  end

  # The place question searches every selectable stop in the alert's version.
  # The boarding alternative searches what the alert has not already made
  # unusable, with the chosen routes' own stops first so "the next stop on this
  # route" reads at the top of the list (AC-18).
  defp stop_search(socket, :place, text) do
    Alerts.search_stops(audit_context(socket), text)
  end

  defp stop_search(socket, :alternative, text) do
    answer = scope(socket.assigns.alert)

    Alerts.search_stops(audit_context(socket), text,
      exclude_stop_ids: answer.stop_ids || [],
      prefer_route_ids: answer.route_ids || []
    )
  end

  # The stored stop's own label decides whether the text still names it. A
  # different text is an edit over a selection, and a blank one is a clear.
  defp clear_edited_label(socket, kind, text) do
    alert = socket.assigns.alert
    chosen = chosen_stop_id(alert, kind)

    cond do
      chosen == nil ->
        socket

      text == stop_label(socket, chosen) ->
        socket

      true ->
        forget_stop(socket, kind, chosen)
    end
  end

  # Written directions and a chosen stop are two answers to one question, so
  # either one clearing the other is the rule rather than a special case.
  defp forget_stop(socket, :place, chosen) do
    write_stop(socket, %{"scope" => %{"stop_ids" => []}})
    |> clear_combobox(:place, chosen)
  end

  defp forget_stop(socket, :alternative, chosen) do
    write_stop(socket, %{"scope" => %{"alternative_stop_id" => nil}})
    |> clear_combobox(:alternative, chosen)
  end

  defp clear_combobox({:noreply, socket}, kind, _chosen) do
    send_update(LiveSelectComponent,
      id: Map.fetch!(@stop_search_kinds, kind),
      value: nil,
      options: []
    )

    socket
  end

  defp clear_combobox(other, _kind, _chosen), do: other
  # The two ends travel as form fields, so a select that changed its value but
  # not its selection is still readable here.
  # The slice of the route's own stop list between two named ends, or `nil` when
  # either end is not a stop of that list.
  defp stretch_stops(socket, from_id, to_id, options) do
    known = Alerts.stops_by_id(audit_context(socket), [from_id, to_id])
    order = Enum.map(options, & &1.id)

    with %{id: from} <- Map.get(known, from_id, %{}),
         %{id: to} <- Map.get(known, to_id, %{}),
         a when is_integer(a) <- Enum.find_index(order, &(&1 == from.id)),
         b when is_integer(b) <- Enum.find_index(order, &(&1 == to.id)) do
      Enum.slice(order, min(a, b), abs(a - b) + 1)
    else
      _not_on_this_route -> nil
    end
  end

  # -- Stop answers ------------------------------------------------------

  # Every stop answer goes through the one writer. A `nil` alert is the new-alert
  # frame, which writes nothing before the first answer (AC-15, INV-1).
  defp write_stop(socket, attrs) do
    case socket.assigns.alert do
      nil -> {:noreply, socket}
      alert -> save(socket, alert, attrs)
    end
  end

  # A chosen place is the alert's own stop. The routes serving it are preselected,
  # because a place question exists to name a place and the routes that call at
  # it are what the alert is about; the editor removes any that are not affected
  # on the routes question, which is where a route is chosen at all.
  #
  # The identity is re-read through the scoped lookup first, so a stop of another
  # version is absent from the result and nothing is written for it (R1, CR-4).
  defp pick_place(socket, alert, id, params) do
    with %{^id => stop} <- Alerts.stops_by_id(audit_context(socket), [id]) do
      serving = Enum.map(Alerts.routes_at_stops(audit_context(socket), [id]), & &1.id)

      attrs =
        with_scope(params, %{
          "shape" => "stop_all_routes",
          "stop_ids" => [id],
          "route_ids" => serving,
          "all_routes_at_stops" => true
        })

      case save(socket, alert, attrs) do
        {:noreply, socket} ->
          {:noreply, socket |> reset_stop_fields() |> send_chosen(:place, stop)}

        other ->
          other
      end
    else
      _not_in_this_version -> {:noreply, reset_stop_fields(socket)}
    end
  end

  # A chosen boarding stop and written directions are two answers to one
  # question, so choosing the stop clears the text. The alternative search
  # already excluded the affected stops, which is why this identity cannot be
  # one of them by accident.
  defp pick_alternative(socket, alert, id, params) do
    with %{^id => stop} <- Alerts.stops_by_id(audit_context(socket), [id]) do
      attrs = with_scope(params, %{"alternative_stop_id" => id, "alternative_directions" => nil})

      case save(socket, alert, attrs) do
        {:noreply, socket} ->
          {:noreply, socket |> reset_stop_fields() |> send_chosen(:alternative, stop)}

        other ->
          other
      end
    else
      _not_in_this_version -> {:noreply, reset_stop_fields(socket)}
    end
  end

  # The rest of the form travels with the selection, so a typed direction typed
  # before the pick is saved with it rather than dropped.
  defp with_scope(%{"alert" => %{"scope" => scope} = params}, answer)
       when is_map(scope) do
    put_in(params, ["scope"], Map.merge(scope, answer))
  end

  defp with_scope(params, _answer), do: Map.delete(params, "revision")

  # `LiveSelect` keeps the option list it first rendered across a parent
  # re-render, so a chosen stop is sent back to its own component with the label
  # that value belongs to.
  defp send_chosen(socket, kind, stop) do
    send_update(LiveSelectComponent,
      id: Map.fetch!(@stop_search_kinds, kind),
      value: stop.id,
      options: [stop_option(stop)]
    )

    socket
  end

  # The pair that makes an unchosen route affected at the stops the alert names.
  # Only the stops that route actually serves appear, so the stored pair can
  # never name a stop the route does not call at.
  defp shared_pairs(socket, alert) do
    answer = scope(alert)
    stops = answer.stop_ids || []
    chosen = MapSet.new(answer.route_ids || [])
    audit = audit_context(socket)

    audit
    |> Alerts.routes_at_stops(stops)
    |> Enum.reject(&MapSet.member?(chosen, &1.id))
    |> Enum.flat_map(fn route ->
      served =
        audit
        |> Alerts.route_stops(route.id)
        |> Enum.map(& &1.id)
        |> MapSet.new()

      stops
      |> Enum.filter(&MapSet.member?(served, &1))
      |> Enum.map(&%{"route_id" => route.id, "stop_id" => &1})
    end)
  end

  defp alternative_required?(%Alert{situation: situation})
       when situation in [:stop_moved, :accessibility],
       do: true

  defp alternative_required?(_alert), do: false

  defp alternative_answered?(%Alert{} = alert) do
    answer = scope(alert)

    not is_nil(answer.alternative_stop_id) or present?(answer.alternative_directions) or
      (alert.situation == :accessibility and present?(answer.facility))
  end

  defp chosen_stop_id(nil, _kind), do: nil
  defp chosen_stop_id(alert, :place), do: (scope(alert).stop_ids || []) |> List.first()
  defp chosen_stop_id(alert, :alternative), do: scope(alert).alternative_stop_id

  # The label the stored stop renders, read through the same scoped lookup a pick
  # uses, so the comparison is between two values this version produced.
  defp stop_label(socket, id) do
    case Map.fetch(Alerts.stops_by_id(audit_context(socket), [id]), id) do
      {:ok, stop} -> stop.label
      :error -> nil
    end
  end

  # The comboboxes read their value from the row rather than from an assign a
  # keystroke could have set, so a cleared identity cannot be re-picked by the
  # next unrelated autosave (R7).
  defp reset_stop_fields(socket) do
    alert = socket.assigns.alert

    socket
    |> assign(:place_field, stop_field(alert, :place))
    |> assign(:boarding_field, stop_field(alert, :alternative))
  end

  defp stop_field(alert, kind), do: to_form(%{"stop_id" => chosen_stop_id(alert, kind)}, as: kind)

  # -- Departures --------------------------------------------------------

  # The date input's own form. It is built from the value the editor typed
  # rather than from the row, because a date the editor has not added yet is
  # not an answer.
  defp service_date_form(value), do: to_form(%{"date" => value}, as: :service_date)

  # The list is only read when the editor is actually on this question, because
  # it is one schedule read per date per chosen route and every other step of
  # every alert would otherwise pay for it on arrival.
  defp prepare_departure_question(socket) do
    if socket.assigns.step == :departures do
      load_departure_dates(socket)
    else
      assign(socket, departure_dates: [], departure_routes?: false)
    end
  end

  defp load_departure_dates(socket) do
    alert = socket.assigns.alert
    routes = route_labels(socket, alert)
    chosen = MapSet.new(scope(alert).trips, &{&1.trip_id, &1.service_date})

    groups =
      Enum.map(working_dates(socket, alert), fn date ->
        departures =
          alert
          |> departure_lists(socket, date)
          |> List.flatten()
          |> Enum.sort_by(&{&1.first_departure_seconds, &1.trip_id})
          |> Enum.map(fn departure ->
            departure
            |> Map.put(:route_id, departure.route_id)
            |> Map.put(:route_label, departure_route_label(routes, departure.route_id))
            |> Map.put(:selected?, MapSet.member?(chosen, {departure.trip_id, date}))
          end)

        %{date: date, departures: departures}
      end)

    socket
    |> assign(:departure_dates, groups)
    |> assign(:departure_routes?, map_size(routes) > 0)
  end

  # The names the alert's own routes are known by, read through the one public
  # labelling read so a departure row, the Rider preview and the review all say
  # the same thing (CR-4).
  defp route_labels(_socket, nil), do: %{}

  defp route_labels(socket, alert) do
    socket |> audit_context() |> Alerts.labels_for(alert) |> Map.fetch!(:routes)
  end

  # The dates this question lists: the ones the alert already names a cancelled
  # trip on, plus the ones the editor added in this session. With neither, the
  # agency's own today is offered, so the question opens on something real
  # rather than on an empty card.
  defp working_dates(socket, alert) do
    stored = scope(alert).trips |> Enum.map(& &1.service_date) |> Enum.reject(&is_nil/1)

    case Enum.sort(Enum.uniq(stored ++ socket.assigns.added_dates)) do
      [] -> [socket |> audit_context() |> Alerts.agency_now() |> NaiveDateTime.to_date()]
      dates -> dates
    end
  end

  # One schedule read per chosen route and date. The direction the alert stores
  # narrows the list; no stored direction means both, which is what "every
  # direction" means (AC-10, CR-4).
  defp departure_lists(nil, _socket, _date), do: []

  defp departure_lists(alert, socket, date) do
    audit = audit_context(socket)
    direction_id = scope(alert).direction_id

    Enum.map(scope(alert).route_ids || [], fn route_id ->
      audit
      |> Alerts.departures_on(route_id, direction_id, date)
      |> Enum.map(&Map.put(&1, :route_id, route_id))
    end)
  end

  # With one route the headsign already names it, so the row repeats nothing.
  defp departure_route_label(routes, route_id) do
    if map_size(routes) < 2, do: nil, else: Map.get(routes, route_id)
  end

  # Whether the schedule really offers this trip on this date. Every offered
  # departure is re-read from the alert's own version, so an identity from
  # another version, a trip that does not run that day, or a trip of a route the
  # alert does not name is absent from the answer and writes nothing (R1, CR-4).
  defp departure_offered?(socket, alert, trip_id, date) do
    Enum.any?(departure_lists(alert, socket, date), &(&1.trip_id == trip_id))
  end

  defp drop_date_pairs(socket, alert, date) do
    kept = Enum.reject(scope(alert).trips, &(&1.service_date == date))

    if length(kept) == length(scope(alert).trips) do
      {:noreply, load_departure_dates(socket)}
    else
      write_stop(socket, %{"scope" => %{"trips" => trip_params(kept)}})
    end
  end

  defp trip_params(trips),
    do: Enum.map(trips, &%{"trip_id" => &1.trip_id, "service_date" => &1.service_date})

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp stop_option(stop) do
    %{label: stop.label, value: stop.id, hint: stop_hint(stop)}
  end

  defp stop_hint(%{platform_code: code}) when is_binary(code) and code != "", do: code
  defp stop_hint(_stop), do: nil

  # -- Autosave ------------------------------------------------------------

  defp save(socket, alert, params) do
    socket =
      socket
      |> assign(:pending_attrs, params)
      |> assign(:save_state, :saving)

    case Alerts.save_draft(
           audit_context(socket),
           alert.id,
           base_revision(params, alert),
           castable(params)
         ) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> assign(:alert, saved)
         |> assign(:conflict, nil)
         |> assign(:pending_attrs, nil)
         |> assign(:form, draft_form(saved))
         |> assign(:save_state, :saved)
         |> rebuild(saved)}

      # A refused write changes nothing in the database, so the form is rebuilt
      # from the refused changeset: the typed values and the field errors both
      # come from what was sent, and nothing on screen is cleared (AC-16).
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:form, draft_form(changeset))
         |> assign(:save_state, :error)}

      # A stale write also changes nothing, but its values are still the ones on
      # screen, so the form keeps them rather than snapping back to the row.
      {:error, {:stale, current}} ->
        {:noreply,
         socket
         |> assign(:form, draft_form(Alert.draft_changeset(alert, castable(params))))
         |> assign(:conflict, current)
         |> assign(:save_state, :error)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, write_error_message(reason))
         |> assign(:save_state, :error)}
    end
  end

  # Saving before leaving is one write with the same outcomes autosave has; the
  # only difference is what happens next. A refusal keeps the editor open.
  defp write_pending(%{assigns: %{alert: nil}} = socket), do: {:ok, socket}

  defp write_pending(%{assigns: %{pending_attrs: nil}} = socket), do: {:ok, socket}

  defp write_pending(%{assigns: %{alert: alert, pending_attrs: params}} = socket) do
    socket = assign(socket, save_state: :saving)

    case Alerts.save_draft(
           audit_context(socket),
           alert.id,
           base_revision(params, alert),
           castable(params)
         ) do
      {:ok, saved} ->
        {:ok,
         socket
         |> assign(:alert, saved)
         |> assign(:pending_attrs, nil)
         |> assign(:form, draft_form(saved))
         |> assign(:save_state, :saved)
         |> rebuild(saved)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:refused, assign(socket, form: draft_form(changeset), save_state: :error)}

      {:error, {:stale, current}} ->
        {:refused,
         assign(
           socket,
           form: draft_form(Alert.draft_changeset(alert, castable(params))),
           conflict: current,
           save_state: :error
         )}

      {:error, reason} ->
        {:refused, put_flash(socket, :error, write_error_message(reason))}
    end
  end

  defp leave_editor(socket) do
    socket
    |> assign(:delete_open?, false)
    |> push_navigate(to: alerts_path(socket))
  end

  # The base revision this write is made against. It comes from the hidden
  # field, which is also what a form recovery replays, so a recovered change is
  # compared against the revision it was composed on rather than the newest one
  # (R6). A missing or unreadable field falls back to the revision this editor
  # last saw, so a hand-made event cannot claim a revision of its own (CR-2).
  defp base_revision(params, alert) do
    case params["revision"] do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {revision, ""} -> revision
          _other -> alert.revision
        end

      _other ->
        alert.revision
    end
  end

  # `revision` is this editor's own base, not an answer, so it never reaches the
  # changeset. Nothing else is dropped: an unknown key is ignored by `cast/3`
  # anyway, and dropping more would silently lose a future step's answer.
  defp castable(params), do: Map.delete(params, "revision")

  # -- The form the questions render inside -------------------------------

  # The form's own source is a changeset built by the same public function the
  # write is built from, so a refused write's errors are exactly the errors this
  # form shows, and the values beside them are the values that were refused
  # rather than the row's older ones.
  defp draft_form(%Ecto.Changeset{} = changeset), do: to_form(changeset, as: :alert)

  defp draft_form(%Alert{} = alert) do
    alert
    |> Alert.draft_changeset(%{})
    |> draft_form()
  end

  # Everything derived from the row is rebuilt after a write, so the step
  # sequence, the progress row and the Rider preview read the revision that was
  # just saved rather than the one before it.
  defp rebuild(socket, alert) do
    flags = editor_flags(socket, alert)

    socket
    |> assign(:flags, flags)
    |> assign(:steps, prepare_steps(steps_for(alert, flags), socket.assigns.step, flags, socket))
    |> assign(:preview, preview(socket, alert))
    |> prepare_stop_questions(alert)
  end

  # -- Loading ------------------------------------------------------------

  defp load_editor(socket, params) do
    socket = assign(socket, :mode, mode_from(params, socket))

    case socket.assigns.live_action do
      :new -> build(socket, nil, params)
      :edit -> load_saved(socket, params)
    end
  end

  defp load_saved(socket, params) do
    audit = audit_context(socket)

    case Alerts.get_alert(audit, socket.assigns.alert_id) do
      {:ok, alert} ->
        build(socket, alert, params)

      {:error, :forbidden} ->
        leave(socket, "You no longer have permission to change alerts here.")

      {:error, :not_found} ->
        # R1: the alert's content was never read, because `get_alert/2` scoped the
        # load to this version. Naming the version it belongs to is the only
        # question left, and only within this organization.
        case Alerts.version_name_for(audit, socket.assigns.alert_id) do
          {:ok, name} -> leave(socket, "That alert belongs to #{name}.")
          {:error, _reason} -> leave(socket, "That alert is not available here.", :error)
        end
    end
  end

  defp leave(socket, message, kind \\ :info) do
    socket
    |> put_flash(kind, message)
    |> push_navigate(to: alerts_path(socket))
  end

  # Every assign the templates read is prepared here, so the render function never
  # queries and the preview is one derivation rather than several.
  defp build(socket, alert, params) do
    flags = editor_flags(socket, alert)
    keys = steps_for(alert, flags)
    step = step_from(params, keys, socket)
    prepared = prepare_steps(keys, step, flags, socket)

    socket
    |> assign(:alert, alert)
    |> assign(:load_state, :ready)
    |> assign(:flags, flags)
    |> assign(:steps, prepared)
    |> assign(:step, step)
    |> assign(:preview, preview(socket, alert))
    |> assign(:delete_open?, false)
    |> assign(:save_state, if(is_nil(alert), do: :idle, else: :saved))
    |> assign(:conflict, nil)
    |> assign(:pending_attrs, nil)
    |> assign(:route_query, socket.assigns[:route_query] || "")
    |> assign(:route_options, socket.assigns[:route_options] || [])
    |> assign(:route_error, nil)
    |> assign(:mode_route_types, question_options(socket, alert, step, :mode_route_types))
    |> assign(:directions, question_options(socket, alert, step, :directions))
    |> assign(:stop_error, nil)
    |> assign(:departure_error, nil)
    |> assign(:stretch_ends, %{})
    |> assign(:directions_open?, false)
    |> assign(:form, draft_form(alert || %Alert{}))
    |> prepare_stop_questions(alert)
  end

  # The three reads the stop questions need, taken when the row changes rather
  # than in the render function: the route's own stop list for the skipped-stop
  # question, the routes that share the stops the alert names, and the combobox
  # fields. Every read goes through the audit context, so all three are the
  # alert's own version's (CR-4).
  defp prepare_stop_questions(socket, alert) do
    socket
    |> reset_stop_fields()
    |> assign(:route_stop_options, route_stop_options(socket, alert))
    |> assign(:shared_routes, shared_route_options(socket, alert))
    |> prepare_departure_question()
  end

  # The prototype's skipped-stop list is the chosen route's own stops, in the
  # order riders meet them. Several chosen routes contribute their stops in the
  # order the routes were named, without a stop appearing twice.
  defp route_stop_options(_socket, nil), do: []

  defp route_stop_options(socket, alert) do
    audit = audit_context(socket)

    (scope(alert).route_ids || [])
    |> Enum.flat_map(&Alerts.route_stops(audit, &1))
    |> Enum.uniq_by(& &1.id)
  end

  # The routes the alert does not name that also serve the stops it does name.
  # Each carries the stops they share, because the question is about those
  # stops and not about a route in the abstract.
  defp shared_route_options(_socket, nil), do: []

  defp shared_route_options(socket, alert) do
    audit = audit_context(socket)
    answer = scope(alert)
    chosen = MapSet.new(answer.route_ids || [])
    stops = answer.stop_ids || []

    audit
    |> Alerts.routes_at_stops(stops)
    |> Enum.reject(&MapSet.member?(chosen, &1.id))
    |> Enum.map(fn route ->
      served =
        audit
        |> Alerts.route_stops(route.id)
        |> Enum.map(& &1.id)
        |> MapSet.new()

      shared = Enum.filter(stops, &MapSet.member?(served, &1))
      %{route: route, stops: Map.new(Alerts.stops_by_id(audit, shared), &{&1.id, &1.label})}
    end)
  end

  # The two questions that need more than the alert's own answers read their
  # options when the editor is actually on them: the mode question offers the
  # version's route types and the direction question the directions the routes
  # the alert already names run. Both reads go through the audit context, so
  # they are the alert's own version's (CR-4).
  defp question_options(_socket, nil, _step, _kind), do: []

  defp question_options(socket, _alert, :mode, :mode_route_types) do
    Alerts.route_types(audit_context(socket))
  end

  defp question_options(socket, alert, :direction, :directions) do
    Alerts.route_directions(audit_context(socket), scope(alert).route_ids || [])
  end

  defp question_options(_socket, _alert, _step, _kind), do: []

  defp step_from(params, keys, _socket) do
    requested =
      case params["step"] do
        key when is_binary(key) -> Enum.find(keys, &(Atom.to_string(&1) == key))
        _other -> nil
      end

    requested || List.first(keys)
  end

  # `mode` and `step` are the editor's whole URL state, so both are normalized
  # here and nowhere else. An unknown mode falls back to the reader's preference
  # and an unknown or stale step falls back to the first question this alert
  # asks, rather than showing a question it does not.
  defp mode_from(%{"mode" => value}, socket) when is_binary(value) do
    Enum.find(@modes, &(Atom.to_string(&1) == value)) || preferred_mode(socket)
  end

  defp mode_from(_params, socket), do: preferred_mode(socket)

  defp preferred_mode(socket) do
    case socket.assigns[:current_user] && socket.assigns.current_user.alert_authoring_mode do
      mode when mode in @modes -> mode
      _other -> :form
    end
  end

  # The two facts about the version and the saved answers that change the
  # sequence. Both reads go through the audit context, which is scoped to the
  # version in the URL - which, after the check above, is the alert's own version
  # (CR-4).
  defp editor_flags(socket, nil) do
    %{multimodal?: length(Alerts.route_types(audit_context(socket))) > 1, shared_routes?: false}
  end

  defp editor_flags(socket, alert) do
    audit = audit_context(socket)

    %{
      multimodal?: length(Alerts.route_types(audit)) > 1,
      shared_routes?: shared_routes?(audit, alert)
    }
  end

  # "Shared" applies when a stop the alert names is also served by a route the
  # alert does not name, because then the editor has to say whether those routes
  # are affected too. Both reads are the alert's own version's.
  defp shared_routes?(audit, alert) do
    referenced = Listing.referenced_ids(alert)
    chosen = MapSet.new(referenced.routes, &to_string/1)

    audit
    |> Alerts.routes_at_stops(referenced.stops)
    |> Enum.any?(fn route -> not MapSet.member?(chosen, to_string(route.id)) end)
  end

  @doc """
  Returns the questions one alert asks, in order (INV-2).

  This is the only source of the editor's step order: the progress row, the Back
  link and the advance after an answer all read the list it returns, so they
  cannot disagree.

  Every sequence starts `urgency` and `situation`, adds `mode` when the version
  runs more than one route type, ends `reason`, `message` and `review`, and puts
  the chosen situation's own middle steps between them. Before a situation is
  chosen the sequence is the two questions that decide it, because every other
  question depends on that answer.
  """
  @spec steps_for(Alert.t() | nil, %{
          required(:multimodal?) => boolean(),
          required(:shared_routes?) => boolean()
        }) :: [atom()]
  def steps_for(nil, _flags), do: [:urgency, :situation]

  def steps_for(%Alert{situation: nil}, _flags), do: [:urgency, :situation]

  def steps_for(%Alert{situation: situation}, flags) do
    middle = Map.get(@middle_steps, situation, [])

    [:urgency, :situation]
    |> Kernel.++(if flags.multimodal?, do: [:mode], else: [])
    |> Kernel.++(resolve_shared(middle, flags))
    |> Kernel.++([:reason, :message, :review])
  end

  defp resolve_shared(middle, %{shared_routes?: true}) do
    Enum.map(middle, fn
      {:shared, :conditional} -> :shared
      step -> step
    end)
  end

  defp resolve_shared(middle, _flags) do
    Enum.reject(middle, &match?({:shared, _}, &1))
  end

  # -- Progress -----------------------------------------------------------

  # Each row carries what the bar needs: position, name, whether the alert holds
  # an answer for it, whether it is the open question, and where it goes. A step
  # the editor has not reached is not a link: there is nothing behind it.
  defp prepare_steps(keys, current, flags, socket) do
    reached = Enum.find_index(keys, &(&1 == current)) || 0

    keys
    |> Enum.with_index()
    |> Enum.map(fn {key, index} ->
      %{
        # LiveView's keyed comprehension reads the `:id` of each item, so a
        # step carries the DOM identity its own link renders.
        id: "alert-step-#{key}",
        key: key,
        label: Map.fetch!(@step_labels, key),
        position: index + 1,
        answered?: answered?(key, flags, socket),
        current?: key == current,
        reachable?: index <= reached,
        patch: editor_path(socket, step: key)
      }
    end)
  end

  # A check beside a question is a claim about stored data, so "answered" is read
  # from the answers the alert holds rather than from a flag the editor sets. A
  # question with no answer yet shows its position instead.
  defp answered?(step, _flags, socket), do: step_answered?(step, socket.assigns.alert)

  defp step_answered?(_step, nil), do: false

  defp step_answered?(:urgency, alert), do: not is_nil(alert.urgency)
  defp step_answered?(:situation, alert), do: not is_nil(alert.situation)
  defp step_answered?(:mode, alert), do: not is_nil(scope(alert).mode_route_type)
  defp step_answered?(:change, alert), do: not is_nil(alert.service_change_kind)

  defp step_answered?(:routes, alert) do
    answer = scope(alert)
    answer.shape == :system or present?(answer.route_ids)
  end

  defp step_answered?(:direction, alert), do: not is_nil(scope(alert).direction_id)
  defp step_answered?(:place, alert), do: present?(scope(alert).stop_ids)

  defp step_answered?(:stops, alert) do
    answer = scope(alert)
    present?(answer.stop_ids) or not is_nil(answer.stretch_from_stop_id)
  end

  defp step_answered?(:shared, alert), do: not is_nil(scope(alert).all_routes_at_stops)

  defp step_answered?(:alternative, alert) do
    answer = scope(alert)
    not is_nil(answer.alternative_stop_id) or present?(answer.alternative_directions)
  end

  defp step_answered?(:departures, alert), do: present?(scope(alert).trips)
  defp step_answered?(:timing, alert), do: not is_nil(alert.timing)
  defp step_answered?(:reason, alert), do: not is_nil(alert.cause)

  defp step_answered?(:message, alert) do
    alert.message && present?(alert.message.header)
  end

  defp step_answered?(:review, alert), do: alert.complete

  # -- Creating, saving and deleting --------------------------------------

  # The next question after an answer, for the answers that were already saved.
  # Nothing is written here, so it is used by Continue and by the whole-system
  # choice once the row holds what the reader chose.
  defp advance_without_writing(socket, alert, answered) do
    push_patch(socket, to: saved_path(socket, alert, advance(alert, answered, socket)))
  end

  # The one writer, used by every question step (INV-1). The advance target is
  # the next question this alert's own sequence puts after the one just answered,
  # so a choice cannot move a reader into a question that does not exist (INV-2).
  # A refusal changes nothing, so the editor stays on the question with the
  # reason rather than advancing over an answer that was not stored.
  defp answer_and_advance(socket, answered, attrs) do
    case socket.assigns.alert do
      nil -> {:noreply, socket}
      alert -> answer_and_advance(socket, answered, alert, attrs)
    end
  end

  defp answer_and_advance(socket, answered, alert, attrs) do
    case Alerts.save_draft(audit_context(socket), alert.id, alert.revision, attrs) do
      {:ok, saved} ->
        {:noreply, advance_without_writing(socket, saved, answered)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, write_error_message(reason))}
    end
  end

  # A card's value is the answer's own value, so a number is read back as the

  # A card's value is the answer's own value, so a number is read back as the
  # number the row stores rather than as text. Anything else is not one of the
  # choices this question offered and advances nothing.
  defp parse_choice(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _other -> :error
    end
  end

  # The route search answers keystrokes, and LiveView sends a `phx-keyup` on a
  # text field as that field's own `value`, while a form replay - LiveViewTest,
  # or form recovery after a reconnect - sends the same field by its `name`.
  # Both name one query, so both are read here rather than one of them quietly
  # doing nothing.
  defp search_query(%{"value" => query}) when is_binary(query), do: query
  defp search_query(%{"route_query" => query}) when is_binary(query), do: query
  defp search_query(_params), do: nil

  defp create_and_advance(socket, urgency) do
    case Alerts.create_alert(audit_context(socket), %{"urgency" => urgency}) do
      {:ok, alert} ->
        {:noreply,
         push_navigate(socket, to: saved_path(socket, alert, advance(alert, :urgency, socket)))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, write_error_message(reason))}
    end
  end

  # The next question is the one this alert's own sequence puts after the step
  # just answered. The flags the editor already holds are reused rather than read
  # again: the version's route types have not changed while this editor is open,
  # and the shared-stop question is decided by the answer just saved.
  defp advance(alert, answered, socket) do
    keys = steps_for(alert, socket.assigns.flags)

    case Enum.find_index(keys, &(&1 == answered)) do
      nil -> answered
      index -> Enum.at(keys, index + 1, answered)
    end
  end

  defp delete_alert(socket, alert) do
    case Alerts.delete_alert(audit_context(socket), alert.id, alert.revision) do
      {:ok, _deleted} ->
        socket
        |> assign(:delete_open?, false)
        |> put_flash(:info, "That alert was deleted.")
        |> push_navigate(to: alerts_path(socket))

      {:error, :stale, _current} ->
        socket
        |> assign(:delete_open?, false)
        |> put_flash(:error, deletion_refused_message())

      {:error, reason} ->
        socket
        |> assign(:delete_open?, false)
        |> put_flash(:error, write_error_message(reason))
    end
  end

  # -- URL paths ----------------------------------------------------------

  defp editor_path(socket, opts) do
    step = Keyword.get(opts, :step, socket.assigns.step)
    mode = Keyword.get(opts, :mode, socket.assigns.mode)
    query = URI.encode_query(%{"mode" => to_string(mode), "step" => to_string(step)})

    case socket.assigns.alert do
      nil -> "#{new_path(socket)}?#{query}"
      alert -> "#{saved_base_path(socket, alert)}?#{query}"
    end
  end

  defp saved_path(socket, alert, step) do
    query =
      URI.encode_query(%{"mode" => to_string(socket.assigns.mode), "step" => to_string(step)})

    "#{saved_base_path(socket, alert)}?#{query}"
  end

  defp saved_base_path(socket, alert), do: "/gtfs/#{version_id(socket)}/alerts/#{alert.id}"
  defp new_path(socket), do: "/gtfs/#{version_id(socket)}/alerts/new"
  defp alerts_path(socket), do: "/gtfs/#{version_id(socket)}/alerts"

  defp version_id(socket), do: socket.assigns.current_gtfs_version.id

  # -- The Rider preview --------------------------------------------------

  # The preview reads saved answers only: the header the editor wrote, the When
  # sentence `Recurrence.summary/1` derived, and the route rows
  # `Alerts.routes_for/2` read from the alert's own version (CR-4).
  defp empty_preview do
    %{
      alert: nil,
      header: nil,
      when_summary: "",
      effect: nil,
      routes: [],
      where: nil,
      what: nil
    }
  end

  defp preview(_socket, nil), do: empty_preview()

  defp preview(socket, alert) do
    audit = audit_context(socket)
    referenced = Listing.referenced_ids(alert)
    routes = Alerts.routes_for(audit, [alert])

    %{
      alert: alert,
      header: alert.message && alert.message.header,
      when_summary: Recurrence.summary(alert.timing),
      effect: Completion.effect_for(alert),
      routes: Enum.map(referenced.routes, &Map.get(routes, &1)) |> Enum.reject(&is_nil/1),
      where: where_phrase(referenced.routes, routes, referenced.stops),
      what: what_phrase(alert)
    }
  end

  defp where_phrase(_route_ids, routes, _stop_ids) when map_size(routes) == 0, do: nil

  defp where_phrase(route_ids, routes, stop_ids) do
    names =
      route_ids
      |> Enum.map(&Map.get(routes, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(", ", &AlertComponents.route_label/1)

    names = if names == "", do: "Every route in this version", else: names
    names <> stop_phrase(stop_ids)
  end

  defp stop_phrase(stop_ids) do
    case Enum.uniq(stop_ids) do
      [] -> ""
      [_one] -> " · 1 stop"
      many -> " · #{length(many)} stops"
    end
  end

  defp what_phrase(%{situation: nil}), do: nil

  defp what_phrase(alert) do
    [
      AlertComponents.effect_label(Completion.effect_for(alert)),
      alert.cause && alert.cause |> to_string() |> String.replace("_", " ")
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" · ")
    |> presence()
  end

  defp presence(""), do: nil
  defp presence(text), do: text

  # -- Questions ----------------------------------------------------------

  defp question_for(:timing, %Alert{urgency: :now}), do: "When should this alert end?"

  defp question_for(step, _alert) do
    Map.fetch!(@questions, step)
  end

  # The single-choice questions say what moving on means; the multi-select says
  # what it needs instead, because Continue is what carries a reader on there.
  defp question_hint(:routes), do: "Choose at least one route, or the whole system."
  defp question_hint(:stops), do: "Choose the stops riders cannot use, or a stretch of them."

  defp question_hint(:departures),
    do: "Choose the departures that will not run, and the dates they run on."

  defp question_hint(:place), do: "Search this version's stops by name or number."

  defp question_hint(_step), do: "Choose an option to move on. You can go back at any time."

  # The questions this step renders. Everything else in the sequence belongs to a
  # later step and still says so rather than rendering an empty card.
  @choice_steps [
    :urgency,
    :situation,
    :mode,
    :change,
    :routes,
    :direction,
    :place,
    :stops,
    :shared,
    :alternative,
    :message
  ]

  defp placeholder_step?(step), do: step not in @choice_steps

  defp selected_route_ids(nil), do: []
  defp selected_route_ids(alert), do: scope(alert).route_ids || []

  defp system_scope?(nil), do: false
  defp system_scope?(alert), do: scope(alert).shape == :system

  # The prototype offers a whole-system choice everywhere except a detour and a
  # cancellation, where naming the routes and the stops is the whole question
  # (spec 4.3 offers it for a suspension).
  defp system_scope_offered?(%Alert{situation: situation})
       when situation in [:detour, :cancelled_trips],
       do: false

  defp system_scope_offered?(_alert), do: true

  # The prototype's eyebrow: when the alert applies, then what it is about, so a
  # reader who comes back to a question knows both at a glance.
  defp eyebrow(alert) do
    [eyebrow_when(alert), eyebrow_what(alert)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp eyebrow_when(nil), do: "Start an alert"
  defp eyebrow_when(%Alert{urgency: :now}), do: "Happening now"
  defp eyebrow_when(%Alert{urgency: :planned}), do: "Planned alert"
  defp eyebrow_when(_alert), do: "Start an alert"

  defp eyebrow_what(nil), do: ""
  defp eyebrow_what(%Alert{situation: nil}), do: ""
  defp eyebrow_what(%Alert{situation: situation}), do: AlertComponents.situation_label(situation)

  # -- Shared helpers -----------------------------------------------------

  defp scope(%Alert{scope: nil}), do: %GtfsPlanner.Alerts.ScopeAnswer{}
  defp scope(%Alert{scope: answer}), do: answer

  defp present?(nil), do: false
  defp present?(list) when is_list(list), do: list != []
  defp present?(_other), do: true

  defp deletion_refused_message do
    "That alert changed since this page was loaded, so it was not deleted. Reload it and try again."
  end

  defp write_error_message(:forbidden) do
    "You no longer have permission to change alerts in this organization."
  end

  defp write_error_message(:not_found) do
    "This alert is no longer available in this service version."
  end

  defp write_error_message(:stale),
    do: "This alert changed elsewhere. Reload it to see the current draft."

  defp write_error_message(_reason), do: "That change could not be saved."

  defp audit_context(socket) do
    %AuditContext{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      station_stop_id: nil,
      actor_id: socket.assigns.current_user.id,
      actor_email: socket.assigns.current_user.email
    }
  end

  # -- Rendering ----------------------------------------------------------

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
      <div id="alert-editor" class="ds-page">
        <.back_link id="alert-back-link" navigate={~p"/gtfs/#{@current_gtfs_version.id}/alerts"}>
          Alerts
        </.back_link>

        <.header>
          {if @alert, do: "Update alert", else: "New alert"}
          <:subtitle>
            Choose what you know. We'll help with the rest.
          </:subtitle>
          <:actions>
            <.mode_control id="alert-mode" mode={@mode} preferred={@preferred} class="sm:mt-1" />
          </:actions>
        </.header>

        <%= if @mode == :assistant do %>
          <%!-- Step 27 fills this region with the real interview. Until then it
                 exists, so switching modes moves between two frames of the same
                 shape rather than between a page and a placeholder page. --%>
          <div
            id="alert-assistant"
            class="mt-5 rounded-card border border-subtle bg-white p-4 sm:p-6"
          >
            <h2 class="text-base font-bold text-strong">Describe the situation</h2>
            <p class="mt-1 text-sm text-muted">
              Tell the assistant what happened and it will prepare a draft you can check and
              change. Your draft is kept either way.
            </p>
          </div>
        <% else %>
          <div class="mt-5 grid gap-6 lg:grid-cols-[minmax(0,1fr)_360px]">
            <div class="min-w-0">
              <.progress steps={@steps} />

              <.conflict_banner :if={@conflict} id="alert-conflict" />

              <.form
                for={@form}
                id="alert-form"
                phx-change="autosave"
                phx-submit="save_and_close"
              >
                <%!-- The base revision this editor writes against. It is a hidden
                       field rather than a server assign because a change replayed
                       by form recovery after a reconnect must still carry the
                       revision it was composed on (R6). --%>
                <input type="hidden" name="alert[revision]" value={@alert && @alert.revision} />

                <.question_card
                  id="alert-question"
                  step={@step}
                  eyebrow={eyebrow(@alert)}
                  heading={question_for(@step, @alert)}
                  hint={question_hint(@step)}
                  back={back_patch(@steps, @step)}
                >
                  <.urgency_question
                    :if={@step == :urgency}
                    alert={@alert}
                    event="choose_urgency"
                    name="urgency"
                  />

                  <.situation_question
                    :if={@step == :situation}
                    alert={@alert}
                    event="choose_situation"
                  />

                  <.mode_question
                    :if={@step == :mode}
                    alert={@alert}
                    event="choose_mode"
                    route_types={@mode_route_types}
                  />

                  <.change_question
                    :if={@step == :change}
                    alert={@alert}
                    event="choose_change"
                  />

                  <.routes_question
                    :if={@step == :routes}
                    options={@route_options}
                    selected={selected_route_ids(@alert)}
                    query={@route_query}
                    error={@route_error}
                    system_selected?={system_scope?(@alert)}
                    allow_system?={system_scope_offered?(@alert)}
                  />

                  <.direction_question
                    :if={@step == :direction}
                    alert={@alert}
                    event="choose_direction"
                    directions={@directions}
                  />

                  <.place_question :if={@step == :place} field={@place_field} />

                  <.stops_question
                    :if={@step == :stops}
                    options={@route_stop_options}
                    selected={scope(@alert).stop_ids || []}
                    stretch={@stretch_ends}
                    error={@stop_error}
                  />

                  <.shared_question
                    :if={@step == :shared}
                    routes={@shared_routes}
                    all_routes?={scope(@alert).all_routes_at_stops}
                  />

                  <.alternative_question
                    :if={@step == :alternative}
                    alert={@alert}
                    form={@form}
                    field={@boarding_field}
                    directions_open?={@directions_open?}
                    error={@stop_error}
                  />

                  <.departures_question
                    :if={@step == :departures}
                    dates={@departure_dates}
                    form={@service_date_form}
                    routes_chosen?={@departure_routes?}
                    error={@departure_error}
                  />

                  <.message_fields
                    :if={@step == :message}
                    form={@form}
                  />

                  <p :if={placeholder_step?(@step)} class="text-sm text-muted">
                    This question is still being added. Everything you have already answered is saved.
                  </p>

                  <:actions>
                    <%!-- The one question in this step that is not self-contained.
                         Its choices are already saved; Continue is the explicit
                         action that moves on, and it refuses to move when
                         nothing is chosen. --%>
                    <.button
                      :if={@step == :routes}
                      id="alert-routes-continue"
                      type="button"
                      variant="primary"
                      class="ml-auto"
                      phx-click="continue_routes"
                    >
                      Continue
                    </.button>

                    <.button
                      :if={@step == :stops}
                      id="alert-stops-continue"
                      type="button"
                      variant="primary"
                      class="ml-auto"
                      phx-click="continue_stops"
                    >
                      Continue
                    </.button>

                    <.button
                      :if={@step == :alternative}
                      id="alert-alternative-continue"
                      type="button"
                      variant="primary"
                      class="ml-auto"
                      phx-click="continue_alternative"
                    >
                      Continue
                    </.button>

                    <.button
                      :if={@step == :departures}
                      id="alert-departures-continue"
                      type="button"
                      variant="primary"
                      class="ml-auto"
                      phx-click="continue_departures"
                    >
                      Continue
                    </.button>
                  </:actions>
                </.question_card>
              </.form>
            </div>

            <.rider_preview
              alert={@preview.alert}
              header={@preview.header}
              when_summary={@preview.when_summary}
              effect={@preview.effect}
              routes={@preview.routes}
              where={@preview.where}
              what={@preview.what}
            />
          </div>
        <% end %>

        <.save_bar
          id="alert-save-bar"
          status={save_status(@alert, @save_state)}
          state={@save_state}
          show_delete?={not is_nil(@alert)}
          back_path={~p"/gtfs/#{@current_gtfs_version.id}/alerts"}
          form_id={if @mode == :form, do: "alert-form"}
        />

        <.confirm_dialog
          :if={@alert}
          id="delete-alert-dialog"
          open={@delete_open?}
          title="Delete this alert?"
          confirm_label="Delete alert"
          cancel_label="Keep alert"
          pending_label="Deleting…"
          confirm_variant="danger"
          on_cancel="cancel_delete"
          on_confirm="confirm_delete"
          described_by="delete-alert-dialog-body"
          return_focus_id="delete-alert"
        >
          <p id="delete-alert-dialog-body">
            Delete "{alert_title(@alert)}"? This cannot be undone.
          </p>
        </.confirm_dialog>
      </div>
    </Layouts.app>
    """
  end

  defp back_patch(steps, current) do
    keys = Enum.map(steps, & &1.key)

    case Enum.find_index(keys, &(&1 == current)) do
      index when is_integer(index) and index > 0 ->
        Enum.find(steps, &(&1.key == Enum.at(keys, index - 1))) |> Map.get(:patch)

      _other ->
        nil
    end
  end

  defp alert_title(%Alert{message: %{header: header}}) when is_binary(header) do
    if String.trim(header) == "", do: "this alert", else: header
  end

  defp alert_title(_alert), do: "this alert"

  # The status line says only what has actually happened to this editor's own
  # writes. `Saved` appears only after the server acknowledged the write, so the
  # line can never claim a save the database refused (FH-16). A draft that has
  # never been written says so, because "Nothing saved yet" is a true and
  # different thing from "Not saved.".
  defp save_status(nil, :idle), do: "No alert saved yet."
  defp save_status(_alert, :idle), do: "Saved."
  defp save_status(_alert, :saving), do: "Saving…"
  defp save_status(_alert, :saved), do: "Saved"
  defp save_status(_alert, :error), do: "Not saved."
end
