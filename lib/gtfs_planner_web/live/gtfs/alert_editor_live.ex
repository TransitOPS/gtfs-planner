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

  ## Message wording, and the callout that never rewrites it

  The message step is the one card with two states. With nothing worded it
  offers this organization's scripts - the ones for the alert's own situation
  first - and arriving there generates the text a script would produce, so the
  reader starts from something rather than from an empty form. Editing the text
  marks it `customized` and keeps the digest it was generated from, and a later
  answer that changes a fact makes that digest differ from the current facts:
  that difference is **Review wording** (AC-22, FH-22).

  The callout replaces nothing. The wording stays as it was written, and the two
  actions are the only ways it changes: **Use generated text** writes the
  regenerated text, and **I checked the message** records the acknowledgement by
  moving the stored digest to the current facts - so the next answer change asks
  again rather than being answered once and for all. The checks beside the text
  are advisory: they are reported, and `Alerts.save_draft/4` reads none of them.

  ## The review, and the one action that finishes an alert

  The last question of every sequence reads the alert back: the exact header
  and description the row stores, the facts beside them, and the guidelines'
  own results. It is a reading of saved answers, so it cannot describe an alert
  the row does not hold, and it carries the Rider preview's own derivations
  rather than a second reading of the same facts.

  **Save alert** is the whole action set of that step. It writes through
  `Alerts.save_draft/4` first, so the question "is this alert finished?" is
  asked of the row this editor holds, and then it runs
  `Alerts.Completion.errors/1` - the same function the row's `complete` flag
  comes from. With questions outstanding they are listed with a link to each
  step that answers one, and the summary takes the reader to the first; with
  none, the editor returns to the list with the flash **Alert saved.**
  (AC-23, FH-23).

  Nothing on this step publishes. There is no Live, Scheduled, Ended, End,
  Publish, Schedule or feed copy here or anywhere else in this LiveView,
  because saving an alert never publishes one in this package (R2, CR-1).

  ## Assistant mode is the same draft, interviewed

  Assistant mode is a second frame over the same row, not a second editor. On
  `/alerts/new` it shows the **Describe the situation** start card, because
  there is no draft to talk about yet and no alert to hold a conversation: the
  first note the reader sends is what creates the draft, through
  `Alerts.create_alert/2`, and the editor then navigates to that row's own
  assistant URL, where `AgentPanel.open/1` attaches to the conversation the
  start card already began.

  Every edit route in assistant mode mounts `AgentPanel` with the `alerts` pack,
  `auto_apply: true` and this alert's own id as the session's subject, and opens
  it. Each settled prepared change arrives as
  `{:agent_prepared, conversation_id, entry_id}`; a message naming another
  conversation, or another alert's session, changes nothing. The change itself
  is applied here and nowhere else: `Agents.prepared/3` returns the model's own
  draft-shaped parameters, they go through `Alerts.save_draft/4` at the revision
  this editor holds, and the entry is recorded applied with the exact command
  that was written (CR-6, INV-1).

  A change prepared against a revision this editor has since replaced is not
  dropped and not forced either: the editor keeps it as a candidate and offers
  **Apply changes**, which re-reads the alert and applies the same parameters at
  whatever revision the row is at then.

  The assistant is a convenience, never a dependency. When the provider cannot
  answer, the panel reports it and the mode control says so, while Form mode
  keeps every answer and every save. **Draft with assistant** on the message
  step asks for wording and puts the request in the composer, so nothing is
  sent that the operator did not read first.

  ## What this frame does not do

  It carries no publication state and no publication action: saving an alert
  never publishes one in this package, so Live, Scheduled, Ended, End and feed
  copy is absent by construction (R2, CR-1). The question bodies belong to the
  steps that own them; this step builds the frame they render inside, creation on
  the first answer, the version check, the preference, the autosave form with its
  save status and conflict banner, **Delete alert**, and the assistant frame the
  interview runs in.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.AgentComponents, only: [agent_panel: 1]

  import GtfsPlannerWeb.Gtfs.AlertComponents,
    only: [
      alternative_question: 1,
      assistant_start: 1,
      change_question: 1,
      conflict_banner: 1,
      departures_question: 1,
      direction_question: 1,
      mode_control: 1,
      mode_question: 1,
      message_question: 1,
      place_question: 1,
      progress: 1,
      question_card: 1,
      reason_question: 1,
      review_actions: 1,
      review_details: 1,
      rider_preview: 1,
      routes_question: 1,
      save_bar: 1,
      shared_question: 1,
      situation_question: 1,
      stops_question: 1,
      timing_question: 1,
      urgency_question: 1
    ]

  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1]

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Completion
  alias GtfsPlanner.Alerts.Listing
  alias GtfsPlanner.Alerts.Message
  alias GtfsPlanner.Alerts.MessageAnswer
  alias GtfsPlanner.Alerts.Recurrence
  alias GtfsPlanner.Alerts.TimingAnswer
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlannerWeb.AgentPanel
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

  # The values this step's own cards offer, so a hand-made event naming anything
  # else stores nothing. Both are the enums `TimingAnswer` itself casts.
  @end_kinds [:confirmed, :estimated, :unknown]
  @patterns [:continuous, :weekly]

  # How long from now a check-in can be set for. These are the offsets the
  # prototype offers and they are resolved against the agency's own clock, so a
  # reminder is a civil time rather than a count of seconds (CR-7).
  @check_in_offsets [15, 30, 60, 120, 240]

  # The request the message step's **Draft with assistant** puts in the composer,
  # so the operator sends it, reads it and changes it rather than having a
  # request they never wrote start a turn on its own.
  @draft_request "Draft the rider message from the answers so far."

  # What `Recurrence` says when a pattern would expand past its own bound, in
  # the editor's words rather than the module's (AC-20).
  @too_many_occurrences "That's too many dates. Shorten the period or choose fewer days."

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
     |> assign(:chosen_timing_date, nil)
     |> assign(:timing_date_form, timing_date_form(nil))
     |> assign(:timing_occurrences, [])
     |> assign(:timing_error, nil)
     |> assign(:check_in_options, [])
     |> assign(:notice_value, nil)
     |> assign(:browse_scripts?, true)
     |> assign(:message_scripts, %{matching: [], other: []})
     |> assign(:message_checks, [])
     |> assign(:message_review?, false)
     |> assign(:message_script_name, nil)
     |> assign(:message_guidelines, "")
     |> assign(:review_errors, [])
     |> assign(:review_checks, [])
     |> assign(:assistant_note_form, assistant_note_form())
     |> assign(:assistant_candidate, nil)
     |> assign(:assistant_filled?, false)
     |> assign(:form, draft_form(%Alert{}))
     |> AgentPanel.mount("alerts", auto_apply: true)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_editor(socket, params)}
  end

  # A settled assistant entry carrying a prepared change belongs to the
  # conversation this editor opened. A message from any other conversation - the
  # alert this editor was showing a moment ago, or another editor's session -
  # changes nothing here, because the id the panel hands over is the only thing
  # that says whose change this is (R11, FH-28).
  @impl true
  def handle_info({:agent_prepared, conversation_id, entry_id}, socket) do
    {:noreply, apply_prepared(socket, conversation_id, entry_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # -- The assistant ------------------------------------------------------

  # The first note is what creates the draft: `/alerts/new` has no row and no
  # conversation to open, so the editor creates the row, opens that row's
  # session, sends the note and navigates to the row's own assistant URL. The
  # conversation is keyed by the alert, so the URL the navigation lands on
  # attaches to the turn the start card began rather than starting a second one.
  def handle_event("assistant_start", %{"assistant" => %{"note" => note}}, socket)
      when is_binary(note) do
    case String.trim(note) do
      "" ->
        {:noreply, socket}

      text ->
        {:noreply, start_interview(socket, text)}
    end
  end

  def handle_event("assistant_start", _params, socket), do: {:noreply, socket}

  # A sample situation fills the note rather than sending it: the reader can
  # change the example into their own words before the interview begins.
  def handle_event("assistant_example", %{"text" => text}, socket) when is_binary(text) do
    {:noreply, assign(socket, :assistant_note_form, assistant_note_form(text))}
  end

  def handle_event("assistant_example", _params, socket), do: {:noreply, socket}

  # **Draft with assistant** asks for wording in the reader's own composer. The
  # request is typed into the form, not sent, so the turn starts only when the
  # reader sends it.
  def handle_event("draft_with_assistant", _params, socket) do
    {:noreply,
     socket
     |> assign(:mode, :assistant)
     |> assign(:agent_form, to_form(%{"message" => @draft_request}, as: :agent))
     |> push_patch(to: editor_path(socket, mode: :assistant))}
  end

  # A candidate the editor could not apply because the row moved under it is
  # applied here, against whatever revision the row is at now.
  def handle_event("apply_assistant_changes", %{"entry" => entry}, socket)
      when is_binary(entry) do
    case socket.assigns.assistant_candidate do
      %{entry_id: entry_id} = candidate ->
        {:noreply,
         if(to_string(entry_id) == entry, do: apply_candidate(socket, candidate), else: socket)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("apply_assistant_changes", _params, socket), do: {:noreply, socket}

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

  # The reason question's cards (AC-21). Every cause but one is a self-contained
  # choice, so it saves and advances like any other; changing cause also drops
  # any other-reason explanation, because a description of a crash the alert no
  # longer says is why would otherwise still be in the rider's message.
  #
  # "Other reason" is the one card with a second field: it saves and reveals
  # "Describe the other reason", and Continue is what carries the reader on
  # (AC-17). The value is checked against the cards this question rendered, so
  # a hand-made event stores nothing.
  def handle_event("choose_cause", %{"cause" => cause}, socket) when is_binary(cause) do
    case AlertComponents.cause_choice(cause) do
      nil ->
        {:noreply, socket}

      %{value: "other_cause"} ->
        write_without_advancing(socket, %{"cause" => cause})

      %{value: chosen} ->
        answer_and_advance(socket, :reason, %{"cause" => chosen, "cause_detail" => nil})
    end
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

  # "Both directions" is a choice like any other, so it saves and advances like
  # any other: it stores no direction at all, which is how the scope answer says
  # "every direction". The other cards store their own number.
  def handle_event("choose_direction", %{"direction" => "both"}, socket) do
    answer_and_advance(socket, :direction, %{"scope" => %{"direction_id" => nil}})
  end

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

  # The place is one combobox answer rather than a self-contained card, so a
  # chosen result is written at once and Continue is the explicit action that
  # carries the reader on to the routes question the place preselects. It
  # refuses while nothing is chosen, so the sequence cannot be walked past a
  # question the alert depends on (AC-18, INV-2).
  def handle_event("continue_place", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        if present?(scope(alert).stop_ids) do
          {:noreply, advance_without_writing(socket, alert, :place)}
        else
          {:noreply, assign(socket, :stop_error, "Choose the place this alert is about.")}
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
  def handle_event("autosave", %{"service_date" => %{"date" => value}} = params, socket)
      when is_binary(value) do
    # The date the editor is looking at is not the answer, so only the value is
    # taken from this event; every other field it carries is written as usual.
    socket =
      socket
      |> assign(:chosen_date, parse_date(value))
      |> assign(:service_date_form, service_date_form(value))

    autosave_alert(socket, params)
  end

  # The exception date is a field inside this same autosave form, so it arrives
  # as this question's own answer rather than as an event of its own. It is
  # only the date the editor is looking at: **Add date** is what puts it on the
  # alert, as a removed date when the pattern already covers it and as an added
  # one when it does not.
  def handle_event("autosave", %{"timing_date" => %{"date" => value}} = params, socket)
      when is_binary(value) do
    # As with the service date, the typed date is what **Add date** acts on
    # rather than an answer of its own.
    socket =
      socket
      |> assign(:chosen_timing_date, parse_date(value))
      |> assign(:timing_date_form, timing_date_form(value))

    autosave_alert(socket, params)
  end

  # A check-in is stored as the civil time it falls on rather than as a count of
  # seconds, so it is read in the agency's own zone wherever it is shown (CR-7).
  def handle_event("autosave", %{"check_in_offset" => minutes} = params, socket)
      when is_binary(minutes) do
    # The select is one field of the same form, so its change arrives with every
    # other answer this card holds; the resolved time joins them rather than
    # replacing them.
    params =
      case check_in_at(socket, minutes) do
        nil -> params
        at -> put_in(params, ["alert", "timing", "check_in_at"], at)
      end

    autosave_alert(socket, params)
  end

  # A change to the message's own fields is the operator's wording rather than a
  # script's, so it is stored as `customized` and keeps the digest it was
  # generated from. Keeping that digest is the whole of FH-22: a later answer
  # change makes it differ from the current facts, which is what raises
  # **Review wording** instead of quietly overwriting the text a rider would
  # have read.
  def handle_event("autosave", %{"alert" => %{"message" => message} = params}, socket)
      when is_map(message) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        save(socket, alert, customized_message(params, message))
    end
  end

  def handle_event("autosave", %{"alert" => params} = all, socket) when is_map(params) do
    autosave_alert(socket, all)
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
        case write_without_advancing(socket, %{"scope" => %{"alternative_stop_id" => nil}}) do
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

      write_without_advancing(socket, %{"scope" => %{"shape" => "route_stops", "stop_ids" => ids}})
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

        case write_without_advancing(socket, %{
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

      write_without_advancing(socket, %{
        "scope" => %{"shape" => "trips", "trips" => trip_params(trips)}
      })
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

  # -- Timing -------------------------------------------------------------

  # The end kind decides what this card needs next, so choosing one writes the
  # kind and clears whatever that kind no longer means: a confirmed end expires
  # the alert and has no check-in, an estimate has no end date, and an unknown
  # end has neither (AC-20). The card stays open, because the rest of the answer
  # is still this question's.
  def handle_event("choose_end_kind", %{"end_kind" => kind}, socket) when is_binary(kind) do
    case Enum.find(@end_kinds, &(Atom.to_string(&1) == kind)) do
      nil ->
        {:noreply, socket}

      kind ->
        attrs =
          case kind do
            :confirmed -> %{"end_kind" => kind, "check_in_at" => nil}
            :estimated -> %{"end_kind" => kind, "end_date" => nil}
            :unknown -> %{"end_kind" => kind, "end_time" => nil, "end_date" => nil}
          end

        write_timing(socket, attrs)
    end
  end

  # Once and Repeats each week are two different answers rather than two
  # settings, so choosing one clears the fields the other answer used. The card
  # stays open for the same reason the end kind does.
  def handle_event("choose_pattern", %{"pattern" => pattern}, socket) when is_binary(pattern) do
    case Enum.find(@patterns, &(Atom.to_string(&1) == pattern)) do
      nil ->
        {:noreply, socket}

      :continuous ->
        write_timing(socket, %{
          "pattern" => pattern,
          "weeks" => nil,
          "weekdays" => [],
          "added_dates" => [],
          "removed_dates" => []
        })

      :weekly ->
        write_timing(socket, %{"pattern" => pattern, "last_date" => nil})
    end
  end

  # One day and one write, which is what keeps Back lossless. The weekday is the
  # ISO number the timing answer stores, and a value outside 1 to 7 stores
  # nothing (R12).
  def handle_event("toggle_weekday", %{"day" => day}, socket) when is_binary(day) do
    alert = socket.assigns.alert

    with {iso, ""} <- Integer.parse(day),
         true <- iso in 1..7,
         %{} = alert <- alert do
      chosen = timing_of(alert).weekdays || []
      days = if iso in chosen, do: List.delete(chosen, iso), else: Enum.sort(chosen ++ [iso])

      write_timing(socket, %{"weekdays" => days})
    else
      _not_a_weekday -> {:noreply, socket}
    end
  end

  # **Add date** is one date at a time, because a date inside the pattern is
  # removed while any other date is added - the same two answers the pattern
  # itself has, and the alert stores them as two lists (AC-20).
  def handle_event("add_timing_date", _params, socket) do
    case socket.assigns.chosen_timing_date do
      nil ->
        {:noreply, assign(socket, :timing_error, "Choose a date to add.")}

      date ->
        case timing_of(socket.assigns.alert) do
          %TimingAnswer{} = timing ->
            attrs =
              if in_pattern?(timing, date) do
                %{
                  "removed_dates" => Enum.uniq((timing.removed_dates || []) ++ [date]),
                  "added_dates" => (timing.added_dates || []) -- [date]
                }
              else
                %{
                  "added_dates" => Enum.uniq((timing.added_dates || []) ++ [date]),
                  "removed_dates" => (timing.removed_dates || []) -- [date]
                }
              end

            write_timing(socket, attrs)

          # There is no row to add a date to before the first answer.
          _absent ->
            {:noreply, socket}
        end
    end
  end

  # Putting a date back takes it off whichever list held it, so a removed day
  # rejoins the pattern and an added day leaves the alert.
  def handle_event("remove_timing_date", %{"date" => value}, socket) when is_binary(value) do
    with %Date{} = date <- parse_date(value),
         %{} = alert <- socket.assigns.alert do
      timing = timing_of(alert)

      write_timing(socket, %{
        "added_dates" => (timing.added_dates || []) -- [date],
        "removed_dates" => (timing.removed_dates || []) -- [date]
      })
    else
      _not_a_date -> {:noreply, socket}
    end
  end

  # The timing answers are several fields rather than one self-contained choice,
  # so Continue is the action that moves on, and it moves only once every answer
  # this alert's situation asks for is stored. The message it refuses with is
  # `Completion`'s own, so the question and the review cannot disagree.
  def handle_event("continue_timing", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        case timing_errors(alert) do
          [] ->
            {:noreply, advance_without_writing(socket, alert, :timing)}

          [{_step, _field, message} | _rest] ->
            {:noreply, assign(socket, :timing_error, message)}
        end
    end
  end

  # An answer this card cannot carry on by itself: the other-reason explanation
  # is optional (AC-3), so nothing is refused here and Continue simply carries
  # the reader on.
  def handle_event("continue_reason", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        {:noreply, advance_without_writing(socket, alert, :reason)}
    end
  end

  # The message step's own events (AC-22). The text is several fields rather than
  # one choice, so each of these writes what it changed and nothing carries the
  # reader on: Continue is the explicit action that moves to the review.
  #
  # Choosing a script fills the header and description from the alert's own
  # facts and stores the digest it was generated from, which is what a later
  # answer change is measured against. The key is resolved through the same
  # `Alerts.list_scripts/1` this card rendered, so an event naming a script the
  # reader was never offered stores nothing (the fail-closed shape
  # `choose_cause/3` uses).
  def handle_event("choose_script", %{"key" => key}, socket) when is_binary(key) do
    with alert when not is_nil(alert) <- socket.assigns.alert,
         script when not is_nil(script) <- find_script(socket, key) do
      generate_message(socket, alert, script)
    else
      _no_alert_or_no_such_script -> {:noreply, socket}
    end
  end

  # **Use generated text** is the one action that replaces wording, and it is
  # always an action: the text a script produces is written from the current
  # facts and the row is no longer marked customized, so the review callout has
  # nothing left to report.
  def handle_event("use_generated_text", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        case stored_script(socket, alert) do
          nil -> {:noreply, socket}
          script -> generate_message(socket, alert, script)
        end
    end
  end

  # "I checked the message" records that the wording was read against the
  # answers as they stand now: the stored digest moves to the current facts and
  # the text is not touched. A later answer change produces a different digest
  # and asks again, so acknowledgement is per change rather than permanent.
  def handle_event("confirm_wording", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        digest = alert |> message_facts(socket) |> Message.digest()

        save(socket, alert, %{"message" => %{"fact_digest" => digest}})
    end
  end

  # Showing the chooser is this editor's own view state, not an answer: nothing
  # is written and the wording already stored stays exactly as it is, so
  # looking at the scripts cannot lose a sentence somebody wrote.
  def handle_event("browse_scripts", _params, socket),
    do: {:noreply, assign(socket, :browse_scripts?, true)}

  def handle_event("write_own_message", _params, socket),
    do: {:noreply, assign(socket, :browse_scripts?, false)}

  # The message is several fields, each already saved by its own change, so
  # Continue only carries the reader on. Nothing is refused here: the wording
  # checks are advisory, and a header over the advisory limit still saves
  # (AC-22).
  def handle_event("continue_message", _params, socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        {:noreply, advance_without_writing(socket, alert, :message)}
    end
  end

  def handle_event("save_alert", _params, socket) do
    # The write goes first, so the completeness question is asked of the row
    # this editor holds rather than of the row as it was before the last
    # answer. A refused or stale write keeps the editor open, exactly as
    # `save_and_close` does, rather than answering a question about a row the
    # database refused (INV-1, R6).
    case write_pending(socket) do
      {:ok, socket} -> finish_review(socket)
      {:refused, socket} -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # **Save alert** is the review's one action. The outstanding questions come
  # from `Alerts.Completion.errors/1` - the same function the `complete` flag
  # the row stores is derived from - so a draft with none is finished, and a
  # draft with some is told exactly which step answers each one (AC-23).
  defp finish_review(socket) do
    case socket.assigns.alert do
      nil ->
        {:noreply, socket}

      alert ->
        case Completion.errors(alert) do
          [] ->
            {:noreply,
             socket
             |> put_flash(:info, "Alert saved.")
             |> push_navigate(to: alerts_path(socket))}

          errors ->
            {:noreply, assign(socket, :review_errors, review_failures(socket, errors))}
        end
    end
  end

  # Each outstanding question links to the editor's own URL for the step that
  # answers it, so the summary is a way through rather than a list to read
  # (AC-23). The step key is `Completion`'s own, and the editor falls back to
  # the first question of the sequence for a step this alert's situation does
  # not ask, so a stale key cannot send a reader nowhere.
  defp review_failures(socket, errors) do
    Enum.map(errors, fn {step, _field, message} ->
      %{href: editor_path(socket, step: step), msg: message}
    end)
  end

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
    write_without_advancing(socket, %{"scope" => %{"stop_ids" => []}})
    |> clear_combobox(:place, chosen)
  end

  defp forget_stop(socket, :alternative, chosen) do
    write_without_advancing(socket, %{"scope" => %{"alternative_stop_id" => nil}})
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

  # One change of the editor's own form, whatever else it carries: the row is
  # written through `Alerts.save_draft/4` and never through anything else
  # (INV-1).
  defp autosave_alert(socket, %{"alert" => params}) when is_map(params) do
    case socket.assigns.alert do
      # Nothing has been answered yet, so there is no row to save. The first
      # answer creates it (AC-15); autosave has nothing to write before that.
      nil ->
        {:noreply, socket}

      alert ->
        # A change carrying nothing but the base revision is a control losing
        # focus, not an answer. Writing it would move the row's revision for no
        # change and hand the next write a base nobody typed at.
        if castable(params) == %{} do
          {:noreply, socket}
        else
          save(socket, alert, params)
        end
    end
  end

  defp autosave_alert(socket, _params), do: {:noreply, socket}

  # The civil time a check-in offset falls on, or `nil` for an offset this
  # editor does not offer.
  defp check_in_at(socket, minutes) do
    with {offset, ""} <- Integer.parse(minutes),
         true <- offset in @check_in_offsets do
      NaiveDateTime.add(Alerts.agency_now(audit_context(socket)), offset * 60)
    else
      _not_an_offset -> nil
    end
  end

  # Every answer that is stored without carrying the reader on goes through the
  # one writer. A `nil` alert is the new-alert frame, which writes nothing
  # before the first answer (AC-15, INV-1).
  defp write_without_advancing(socket, attrs) do
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
      write_without_advancing(socket, %{"scope" => %{"trips" => trip_params(kept)}})
    end
  end

  defp trip_params(trips),
    do: Enum.map(trips, &%{"trip_id" => &1.trip_id, "service_date" => &1.service_date})

  # -- Timing answers ----------------------------------------------------

  # Every timing answer goes through the one writer, like every other answer
  # (INV-1). A `nil` alert is the new-alert frame, which writes nothing before
  # the first answer (AC-15).
  # The timing answer is an embed, so its fields travel under the embed's own
  # name: `cast_embed(:timing)` reads `params["timing"]`, and a flat
  # `%{"end_kind" => ...}` is an unknown key that `cast/3` drops without a word.
  # Every timing answer therefore arrives here flat and leaves nested.
  defp write_timing(socket, attrs) do
    case socket.assigns.alert do
      nil -> {:noreply, socket}
      alert -> save(socket, alert, %{"timing" => attrs})
    end
  end

  defp timing_of(%Alert{timing: %TimingAnswer{} = timing}), do: timing
  defp timing_of(_alert), do: nil

  # Whether the pattern itself covers this date, which is what decides whether
  # naming it removes it or adds it. The bounds are the ones
  # `Recurrence.occurrences/1` expands with, so a date the editor can remove is
  # a date the preview was counting.
  defp in_pattern?(
         %TimingAnswer{
           first_date: %Date{} = first_date,
           weeks: weeks,
           weekdays: weekdays
         },
         %Date{} = date
       )
       when is_integer(weeks) and weeks > 0 and is_list(weekdays) do
    offset = Date.diff(date, first_date)
    offset >= 0 and offset < weeks * 7 and Date.day_of_week(date) in weekdays
  end

  defp in_pattern?(_timing, _date), do: false

  # Only the errors this step's own question is responsible for, read from the
  # one completion check the review step also uses, so Continue and the review
  # refuse for the same reasons (AC-20, AC-23).
  defp timing_errors(%Alert{situation: :cancelled_trips}), do: []

  defp timing_errors(%Alert{} = alert) do
    Enum.filter(Completion.errors(alert), &match?({:timing, _field, _message}, &1))
  end

  # The exception date input's own form, built from the date the editor typed
  # rather than from the row, because a date that has not been added is not an
  # answer.
  defp timing_date_form(value), do: to_form(%{"date" => value}, as: :timing_date)

  # The timing question is read from the row rather than queried, so it is
  # prepared where every other step's values are: when the row changes or the
  # editor arrives.
  defp prepare_timing_question(socket, alert) do
    if socket.assigns.step == :timing do
      build_timing_question(socket, alert)
    else
      # The card is the only reader of these, and the agency clock is a read, so
      # no other step pays for them.
      assign(socket,
        timing_occurrences: [],
        timing_error: nil,
        check_in_options: [],
        timing_date_form: timing_date_form(nil),
        notice_value: nil
      )
    end
  end

  defp build_timing_question(socket, alert) do
    now = socket |> audit_context() |> Alerts.agency_now()

    {occurrences, error} =
      case timing_of(alert) do
        %TimingAnswer{} = timing ->
          case Recurrence.occurrences(timing) do
            {:ok, occurrences} -> {occurrences, nil}
            {:error, :too_many} -> {[], @too_many_occurrences}
            {:error, :incomplete} -> {[], nil}
          end

        _absent ->
          {[], nil}
      end

    socket
    |> assign(:timing_occurrences, occurrences)
    |> assign(:timing_error, error)
    |> assign(:check_in_options, check_in_options(now, alert))
    |> assign(:timing_date_form, timing_date_form(iso_or_nil(socket.assigns.chosen_timing_date)))
    |> assign(:notice_value, notice_value(socket, alert, NaiveDateTime.to_date(now)))
  end

  # The offsets the check-in offers, each with the civil time it falls on in the
  # agency's own zone, so the reader sees the clock time they are choosing
  # rather than only an interval (CR-7).
  defp check_in_options(now, alert) do
    chosen = timing_of(alert) && timing_of(alert).check_in_at

    Enum.map(@check_in_offsets, fn minutes ->
      at = NaiveDateTime.add(now, minutes * 60)

      %{
        minutes: minutes,
        at: at,
        label: "In #{minutes} minutes · #{Calendar.strftime(at, "%-I:%M %p")}",
        selected?: not is_nil(chosen) and NaiveDateTime.compare(chosen, at) == :eq
      }
    end)
  end

  # What the notice input shows: the value the form holds - which is a refused
  # save's own value when one is on screen - and otherwise the rule's default,
  # the later of today and seven days before the first date (AC-20). Storing
  # nothing is what lets the default follow a date the editor changes later.
  defp notice_value(socket, alert, today) do
    # `@form[:timing]` is the embed's own field, so the answer is one step
    # further on: the form behind it is what holds `notice_on`.
    timing_field = socket.assigns.form && socket.assigns.form[:timing]
    field = timing_field && timing_field.form[:notice_on]

    if is_binary(field && field.value) and field.value != "" do
      field.value
    else
      iso_or_nil(Recurrence.notice_on(timing_of(alert), today))
    end
  end

  defp iso_or_nil(nil), do: nil
  defp iso_or_nil(%Date{} = date), do: Date.to_iso8601(date)

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

  # -- Message -------------------------------------------------------------

  # The message step's own prepares, read when the editor is on that step and
  # reset when it is not: the scripts this organization can word from, the
  # advisory checks over the stored answer and the current facts, and the
  # guidelines. Every read goes through the audit context, so all of them are
  # the alert's own organization's (CR-2, CR-4).
  defp prepare_message_question(socket, nil), do: reset_message_question(socket)

  defp prepare_message_question(socket, alert) do
    if socket.assigns.step == :message do
      audit = audit_context(socket)
      labels = message_labels(socket, alert)
      scripts = Alerts.list_scripts(audit)
      message = message_of(alert)

      socket
      |> assign(:message_scripts, script_groups(scripts, alert))
      |> assign(:message_checks, Message.checks(message, Message.facts(alert, labels)))
      |> assign(:message_review?, Message.review_wording?(alert, labels))
      |> assign(:message_script_name, script_name(scripts, message.script_key))
      |> assign(:message_guidelines, Alerts.get_guidelines(audit).text)
    else
      reset_message_question(socket)
    end
  end

  # Every assign the message question reads exists whether or not the editor is
  # on it, so a template can never raise for an assign only this step's own
  # arrival would have set.
  defp reset_message_question(socket) do
    socket
    |> assign(:message_scripts, %{matching: [], other: []})
    |> assign(:message_checks, [])
    |> assign(:message_review?, false)
    |> assign(:message_script_name, nil)
    |> assign(:message_guidelines, "")
  end

  # Arriving at the message step with wording that is not the operator's own
  # generates the text a script would produce, so the reader starts from
  # something rather than from an empty card. Wording somebody wrote is never
  # regenerated behind their back, and the generation is one revision-checked
  # write like any other answer (AC-22, INV-1).
  defp enter_message_step(socket, alert, step) do
    if step == :message and needs_generated_message?(alert) do
      case generated_alert(socket, alert) do
        {:ok, saved} -> {saved, assign(socket, :browse_scripts?, false)}
        :refused -> {alert, assign(socket, :browse_scripts?, browsing_scripts?(alert))}
      end
    else
      {alert, assign(socket, :browse_scripts?, browsing_scripts?(alert))}
    end
  end

  defp generated_alert(socket, alert) do
    case stored_script(socket, alert) do
      nil -> :refused
      script -> store_message(socket, alert, script)
    end
  end

  # The generated text, stored. This is the only place in the editor that writes
  # `MessageAnswer.fact_digest`, and it writes the digest of the facts the text
  # was generated from, which is what a later answer change is measured against.
  defp store_message(socket, alert, script) do
    attrs = message_attrs(alert, script, message_labels(socket, alert))

    case Alerts.save_draft(audit_context(socket), alert.id, alert.revision, attrs) do
      {:ok, saved} -> {:ok, saved}
      {:error, _reason} -> :refused
    end
  end

  defp message_attrs(alert, script, labels) do
    generated = Message.generate(alert, script, labels)

    %{
      "message" => %{
        "header" => generated.header,
        "description" => generated.description,
        "script_key" => script.key,
        "customized" => false,
        "fact_digest" => generated.fact_digest
      }
    }
  end

  # Choosing a script and regenerating are the same write: the current facts
  # fill the templates and the wording is no longer marked customized, so the
  # review callout has nothing left to report.
  defp generate_message(socket, alert, script) do
    case save(socket, alert, message_attrs(alert, script, message_labels(socket, alert))) do
      {:noreply, socket} -> {:noreply, assign(socket, :browse_scripts?, false)}
      other -> other
    end
  end

  # The script the stored wording came from, or the one this alert's own
  # situation would be worded from. Either way it is a script this organization
  # was offered, never a template that reached the row by another route.
  defp stored_script(socket, alert) do
    scripts = Alerts.list_scripts(audit_context(socket))

    Enum.find(scripts, &(&1.key == message_of(alert).script_key)) ||
      default_script(scripts, alert)
  end

  defp default_script(scripts, alert) do
    Enum.find(scripts, &(&1.situation == alert.situation)) || List.first(scripts)
  end

  defp find_script(socket, key) do
    Enum.find(Alerts.list_scripts(audit_context(socket)), &(&1.key == key))
  end

  # The scripts for the alert's own situation, then the rest: AC-22 asks for the
  # matches first, and the list order itself is `Alerts.list_scripts/1`'s (the
  # organization's by position, then the built-ins).
  defp script_groups(scripts, alert) do
    {matching, other} = Enum.split_with(scripts, &(&1.situation == alert.situation))

    %{matching: matching, other: other}
  end

  defp script_name(_scripts, nil), do: nil

  defp script_name(scripts, key) do
    case Enum.find(scripts, &(&1.key == key)) do
      nil -> nil
      script -> script.name
    end
  end

  # The labels the fill-ins are filled from: the alert's own routes, stops and
  # trips, plus the direction its scope answer names in a rider's words, because
  # that name lives on the route's trips rather than on the alert.
  defp message_labels(socket, alert) do
    audit = audit_context(socket)
    labels = Alerts.labels_for(audit, alert)

    case scope(alert).direction_id do
      nil ->
        labels

      direction_id ->
        served = Alerts.route_directions(audit, scope(alert).route_ids || [])

        case Enum.find(served, &(&1.direction_id == direction_id)) do
          nil -> labels
          %{label: label} -> Map.put(labels, :direction, "to #{label}")
        end
    end
  end

  defp message_facts(alert, socket), do: Message.facts(alert, message_labels(socket, alert))

  defp message_of(%Alert{message: nil}), do: %MessageAnswer{}
  defp message_of(%Alert{message: message}), do: message

  # Wording that is neither stored nor the operator's own is generated on
  # arrival; wording the operator wrote is left alone (FH-22).
  defp needs_generated_message?(nil), do: false

  defp needs_generated_message?(%Alert{} = alert) do
    is_nil(alert.message) or
      (message_of(alert).customized != true and blank_text?(message_of(alert).header))
  end

  defp browsing_scripts?(nil), do: true

  # The wording is what the operator came for, so arriving with something to read
  # opens the editor and leaves the scripts behind the chooser. The chooser's own
  # state is per arrival rather than remembered across steps: a step that opens
  # with the scripts and no wording to edit is the only case that needs it.
  defp browsing_scripts?(%Alert{} = alert), do: blank_text?(message_of(alert).header)

  defp blank_text?(nil), do: true
  defp blank_text?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank_text?(_other), do: false

  # The alert's own attributes, with the message marked as the operator's. The
  # event carries the whole form, so the alert's params are the inner
  # `%{"message" => ...}` map `Alerts.save_draft/4` casts - handing it the outer
  # form would leave the embed uncast, and a write with no changes looks exactly
  # like a save that happened.
  defp customized_message(params, message) when is_map(message) do
    Map.put(params, "message", Map.put(message, "customized", true))
  end

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
      # `save_draft/4` reports a stale revision as a three-element tuple
      # (`{:error, :stale, current}`); matching the two-element shape here
      # instead left a conflict write with no clause at all, which took the
      # whole LiveView down (R6, AC-11).
      {:error, :stale, current} ->
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

      {:error, :stale, current} ->
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
    |> prepare_questions(alert)
  end

  # -- The assistant -------------------------------------------------------

  # Assistant mode opens the conversation this alert's own session holds, keyed
  # by the alert's id. The subject is taken from the row this editor loaded,
  # never from the URL, so a forged id cannot open a conversation about another
  # alert (CR-2).
  defp prepare_assistant(socket, alert) do
    socket = assign(socket, :agent_subject_id, alert && alert.id)

    if socket.assigns.mode == :assistant and not is_nil(alert) do
      AgentPanel.open(socket)
    else
      socket
    end
  end

  defp start_interview(socket, text) do
    case Alerts.create_alert(audit_context(socket), %{}) do
      {:ok, alert} ->
        socket =
          socket
          |> assign(:alert, alert)
          |> prepare_assistant(alert)

        # The conversation is already open at this point because assistant mode
        # is what the reader was in; the send is what turns the note into a turn.
        :ok = send_assistant_message(socket, text)

        push_navigate(socket, to: saved_path(socket, alert, socket.assigns.step))

      {:error, reason} ->
        socket
        |> put_flash(:error, write_error_message(reason))
    end
  end

  defp send_assistant_message(socket, text) do
    case Agents.send_message(socket.assigns.agent_session, text) do
      :ok -> :ok
      # The draft exists either way, so a refused send only loses the turn the
      # reader asked for, not their alert.
      {:error, _reason} -> :ok
    end
  end

  defp apply_prepared(socket, conversation_id, entry_id) do
    case prepared_change(socket, conversation_id, entry_id) do
      {:ok, alert, params} -> write_prepared(socket, alert, conversation_id, entry_id, params)
      :foreign -> socket
    end
  end

  # The handoff is only acted on when it names the conversation this editor is
  # attached to and the session still holds that proposal.
  defp prepared_change(socket, conversation_id, entry_id) do
    with true <- conversation_id == socket.assigns.agent_conversation_id,
         alert when not is_nil(alert) <- socket.assigns.alert,
         {:ok, %{command: {:alert_changes, params}}} <-
           Agents.prepared(socket.assigns.agent_session, conversation_id, entry_id) do
      {:ok, alert, params}
    else
      _other -> :foreign
    end
  end

  defp write_prepared(socket, alert, conversation_id, entry_id, params) do
    case Alerts.save_draft(audit_context(socket), alert.id, alert.revision, params) do
      {:ok, saved} ->
        socket
        |> assign(:alert, saved)
        |> assign(:form, draft_form(saved))
        |> assign(:save_state, :saved)
        |> assign(:assistant_filled?, true)
        |> rebuild(saved)
        |> record_applied(conversation_id, entry_id, params)

      # A proposal made against an older revision is kept, not forced and not
      # dropped: the row keeps the newer answers and the operator is offered the
      # change as **Apply changes** (AC-28).
      {:error, :stale, current} ->
        socket
        |> assign(:assistant_candidate, %{
          entry_id: entry_id,
          conversation_id: conversation_id,
          params: params
        })
        |> assign(:conflict, current)
        |> assign(:save_state, :error)

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> assign(:form, draft_form(changeset))
        |> assign(:save_state, :error)

      {:error, reason} ->
        socket
        |> put_flash(:error, write_error_message(reason))
        |> assign(:save_state, :error)
    end
  end

  # Applying the kept candidate reads the row first, so the write is made at the
  # revision the row actually holds rather than the one this editor remembers.
  defp apply_candidate(socket, candidate) do
    case Alerts.get_alert(audit_context(socket), socket.assigns.alert.id) do
      {:ok, latest} ->
        socket
        |> write_prepared(
          latest,
          candidate.conversation_id,
          candidate.entry_id,
          candidate.params
        )
        |> assign(:conflict, nil)
        |> assign(:assistant_candidate, nil)

      {:error, reason} ->
        socket
        |> put_flash(:error, write_error_message(reason))
        |> assign(:assistant_candidate, nil)
    end
  end

  defp record_applied(socket, conversation_id, entry_id, params) do
    # The receipt names the command that was actually written, so the session
    # can refuse it if anything changed it in between. A conversation that has
    # ended leaves the row written and the card unconfirmed, which is the same
    # outcome every other apply path in this package has.
    _ =
      Agents.record_applied(
        socket.assigns.agent_session,
        conversation_id,
        entry_id,
        {:alert_changes, params}
      )

    socket
  end

  # The form's own name is `assistant`, so the field renders as
  # `assistant[note]` and the `assistant_start` handler reads what the browser
  # actually submits. The DOM id stays `alert-assistant-note`, which is what the
  # component and the browser journey address.
  defp assistant_note_form(note \\ "") do
    to_form(%{"note" => note}, as: :assistant)
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
    {alert, socket} = enter_message_step(socket, alert, step)
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
    |> assign(:review_errors, [])
    |> assign(:route_query, socket.assigns[:route_query] || "")
    |> assign(:route_options, socket.assigns[:route_options] || [])
    |> assign(:route_error, nil)
    |> assign(:mode_route_types, question_options(socket, alert, step, :mode_route_types))
    |> assign(:directions, question_options(socket, alert, step, :directions))
    |> assign(:stop_error, nil)
    |> assign(:departure_error, nil)
    |> assign(:stretch_ends, %{})
    |> assign(:directions_open?, false)
    |> assign(:chosen_timing_date, socket.assigns[:chosen_timing_date] || nil)
    |> assign(:form, draft_form(alert || %Alert{}))
    |> prepare_questions(alert)
    |> prepare_assistant(alert)
  end

  # The reads the questions that need more than the alert's own answers take,
  # taken when the row changes rather than in the render function: the route's
  # own stop list for the skipped-stop question, the routes that share the stops
  # the alert names, the combobox fields, the cancelled departures and this
  # step's expanded occurrences. Every read goes through the audit context, so
  # all of them are the alert's own version's (CR-4).
  defp prepare_questions(socket, alert) do
    socket
    |> reset_stop_fields()
    |> assign(:route_stop_options, route_stop_options(socket, alert))
    |> assign(:shared_routes, shared_route_options(socket, alert))
    |> prepare_departure_question()
    |> prepare_timing_question(alert)
    |> prepare_message_question(alert)
    |> prepare_review_question(alert)
  end

  # The review reads the same advisory checks the message step read, so the two
  # cannot report different advice about the same stored wording (AC-22,
  # AC-23). The outstanding questions are not read here: they are the answer to
  # **Save alert**, which is the action that asks whether the alert is finished
  # (AC-23), so they are cleared on every arrival and set by that one event.
  defp prepare_review_question(socket, alert) do
    if socket.assigns.step == :review and not is_nil(alert) do
      checks =
        Message.checks(message_of(alert), Message.facts(alert, message_labels(socket, alert)))

      assign(socket, :review_checks, checks)
    else
      assign(socket, :review_checks, [])
    end
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
      %{route: route, stops: stop_labels(audit, shared)}
    end)
  end

  # The labels a shared stop is named by in the question, keyed by the stop's
  # own id because that is what the answer stores. `Alerts.stops_by_id/2`
  # already answers a `%{id => stop}` map, so the labels are read off it: mapping
  # it with `Map.new/2` would run the transform on each `{id, stop}` tuple
  # instead, which is not a map, and took the editor down on the very question
  # that needs it (R6).
  defp stop_labels(audit, ids) do
    audit
    |> Alerts.stops_by_id(ids)
    |> Map.new(fn {id, stop} -> {id, stop.label} end)
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

  defp step_answered?(:timing, %Alert{urgency: :now, timing: timing}),
    do: current_timing_answered?(timing)

  defp step_answered?(:timing, %Alert{timing: %TimingAnswer{first_date: %Date{}}} = alert),
    do: not is_nil(alert.timing.pattern)

  defp step_answered?(:timing, _alert), do: false

  defp step_answered?(:reason, alert), do: not is_nil(alert.cause)

  defp step_answered?(:message, alert) do
    alert.message && present?(alert.message.header)
  end

  defp step_answered?(:review, alert), do: alert.complete

  # The timing embed exists on every row - the zone is written when the draft is
  # created - so an answer means what the question stores, not that a struct is
  # there (AC-20).
  defp current_timing_answered?(nil), do: false

  defp current_timing_answered?(%TimingAnswer{start_date: start_date, end_kind: end_kind}) do
    not is_nil(start_date) and not is_nil(end_kind)
  end

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
      AlertComponents.cause_label(alert.cause)
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

  defp question_hint(:timing),
    do: "Say when this starts and ends, then check the dates it covers."

  defp question_hint(:place), do: "Search this version's stops by name or number."

  defp question_hint(:reason),
    do: "Choose the reason. Describe it in your own words if it is another one."

  defp question_hint(:message),
    do: "Add a headline and details, replace any fill-ins, and check text marked for review."

  defp question_hint(:review),
    do: "Check what riders will see. Saving keeps the alert with this version."

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
    :departures,
    :timing,
    :reason,
    :message
  ]

  defp placeholder_step?(step), do: step not in @choice_steps and step != :review

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
            <.mode_control
              id="alert-mode"
              mode={@mode}
              preferred={@preferred}
              unavailable?={@agent_unavailable?}
              class="sm:mt-1"
            />
          </:actions>
        </.header>

        <%= if @mode == :assistant do %>
          <%!-- Assistant mode is the same draft in a second frame: the start card
                 before there is a row, then the conversation card beside the same
                 Rider preview the form shows. --%>
          <div
            id="alert-assistant"
            class="mt-5 grid gap-6 lg:grid-cols-[minmax(0,1fr)_360px]"
          >
            <div class="min-w-0">
              <.assistant_start
                :if={is_nil(@alert)}
                form={@assistant_note_form}
                examples={@agent_examples}
              />

              <.agent_panel
                :if={not is_nil(@alert) and @agent_open?}
                id="alert-assistant-panel"
                layout={:main}
                title={@agent_title}
                intro={@agent_intro}
                examples={@agent_examples}
                scope_line={"Alerts · " <> @current_gtfs_version.name}
                status={@agent_status}
                entries={@streams.agent_entries}
                form={@agent_form}
                notice={@agent_notice}
                entries_empty?={@agent_entries_empty?}
              />

              <.callout
                :if={@assistant_candidate}
                id="alert-assistant-stale"
                kind="warning"
                title="This alert changed after the assistant prepared these answers."
                class="mt-4 rounded-card"
              >
                <p id="alert-assistant-stale-body">
                  Your own answers stay as they are. Applying these answers writes the assistant's
                  change on top of them at the version this alert is at now.
                </p>
                <div class="mt-3">
                  <.button
                    id={"apply-changes-#{@assistant_candidate.entry_id}"}
                    type="button"
                    variant="primary"
                    phx-click="apply_assistant_changes"
                    phx-value-entry={@assistant_candidate.entry_id}
                    class="min-h-11"
                  >
                    Apply changes
                  </.button>
                </div>
              </.callout>
            </div>

            <.rider_preview
              alert={@preview.alert}
              header={@preview.header}
              when_summary={@preview.when_summary}
              effect={@preview.effect}
              routes={@preview.routes}
              where={@preview.where}
              what={@preview.what}
              assistant?={@assistant_filled?}
            />
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

                  <.place_question
                    :if={@step == :place}
                    field={@place_field}
                    error={@stop_error}
                  />

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

                  <.timing_question
                    :if={@step == :timing}
                    alert={@alert}
                    form={@form}
                    now?={not is_nil(@alert) and @alert.urgency == :now}
                    date_form={@timing_date_form}
                    occurrences={@timing_occurrences}
                    notice_value={@notice_value}
                    check_in_options={@check_in_options}
                    error={@timing_error}
                  />

                  <.reason_question :if={@step == :reason} alert={@alert} form={@form} />

                  <.message_question
                    :if={@step == :message}
                    alert={@alert}
                    form={@form}
                    scripts={@message_scripts}
                    browsing?={@browse_scripts?}
                    script_name={@message_script_name}
                    review?={@message_review?}
                    checks={@message_checks}
                    guidelines={@message_guidelines}
                  />

                  <.review_details
                    :if={@step == :review}
                    alert={@alert}
                    effect={@preview.effect}
                    routes={@preview.routes}
                    header={@preview.header}
                    when_summary={@preview.when_summary}
                    where={@preview.where}
                    what={@preview.what}
                    errors={@review_errors}
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
                      :if={@step == :place}
                      id="alert-place-continue"
                      type="button"
                      variant="primary"
                      class="ml-auto"
                      phx-click="continue_place"
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

                    <%!-- The other-reason explanation is the one answer this step
                         cannot carry a reader on by itself, so Continue is what
                         moves on once it is stored - or once the reader decides
                         not to describe the other reason at all. --%>
                    <.button
                      :if={@step == :reason}
                      id="alert-reason-continue"
                      type="button"
                      variant="primary"
                      class="ml-auto"
                      phx-click="continue_reason"
                    >
                      Continue
                    </.button>

                    <%!-- The timing answers are several fields rather than one
                         self-contained choice, so Continue is what carries the
                         reader on, and it refuses while an answer this
                         situation needs is missing. --%>
                    <.button
                      :if={@step == :timing}
                      id="alert-timing-continue"
                      type="button"
                      variant="primary"
                      class="ml-auto"
                      phx-click="continue_timing"
                    >
                      Continue
                    </.button>

                    <%!-- The message is several fields, each already saved by
                         its own change, so Continue only carries the reader on.
                         Nothing is refused: the wording checks are advisory and
                         a header over the advisory limit still saves
                         (AC-22). --%>
                    <.button
                      :if={@step == :message}
                      id="alert-message-continue"
                      type="button"
                      variant="primary"
                      class="ml-auto"
                      phx-click="continue_message"
                    >
                      Continue
                    </.button>

                    <%!-- Drafting wording with the assistant is the one action on
                         this step that leaves the form. It puts the request in
                         the assistant's own composer, so the turn starts when the
                         operator sends it. --%>
                    <.button
                      :if={@step == :message}
                      id="draft-with-assistant"
                      type="button"
                      variant="secondary"
                      phx-click="draft_with_assistant"
                    >
                      <.icon name="hero-sparkles" class="size-4" /> Draft with assistant
                    </.button>
                  </:actions>
                </.question_card>
              </.form>
            </div>

            <.review_actions :if={@step == :review} effect={@preview.effect} checks={@review_checks} />

            <.rider_preview
              :if={@step != :review}
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
