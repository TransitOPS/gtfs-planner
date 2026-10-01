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

  ## What this frame does not do

  It carries no publication state and no publication action: saving an alert
  never publishes one in this package, so Live, Scheduled, Ended, End and feed
  copy is absent by construction (R2, CR-1). The question bodies belong to the
  steps that own them; this step builds the frame they render inside, creation on
  the first answer, the version check, the preference and **Delete alert**. The
  assistant mode renders a placeholder region its own step fills.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.AlertComponents,
    only: [
      mode_control: 1,
      progress: 1,
      question_card: 1,
      rider_preview: 1,
      save_bar: 1,
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

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @modes [:form, :assistant]

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
     |> assign(:delete_open?, false)}
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
      alert -> save_and_advance(socket, alert, %{"urgency" => urgency})
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

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
  end

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

  defp create_and_advance(socket, urgency) do
    case Alerts.create_alert(audit_context(socket), %{"urgency" => urgency}) do
      {:ok, alert} ->
        {:noreply,
         push_navigate(socket, to: saved_path(socket, alert, advance(alert, :urgency, socket)))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, write_error_message(reason))}
    end
  end

  defp save_and_advance(socket, alert, attrs) do
    case Alerts.save_draft(audit_context(socket), alert.id, alert.revision, attrs) do
      {:ok, saved} ->
        {:noreply,
         push_patch(socket, to: saved_path(socket, saved, advance(saved, :urgency, socket)))}

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
      |> Enum.map_join(", ", & &1.label)

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

  defp eyebrow(nil), do: "Start an alert"
  defp eyebrow(%Alert{urgency: :now}), do: "Happening now"
  defp eyebrow(%Alert{urgency: :planned}), do: "Planned alert"
  defp eyebrow(_alert), do: "Start an alert"

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

              <.question_card
                id="alert-question"
                eyebrow={eyebrow(@alert)}
                heading={question_for(@step, @alert)}
                hint="Choose an option to move on. You can go back at any time."
                back={back_patch(@steps, @step)}
              >
                <.urgency_question
                  :if={@step == :urgency}
                  alert={@alert}
                  event="choose_urgency"
                  name="urgency"
                />

                <p :if={@step != :urgency} class="text-sm text-muted">
                  This question is still being added. Everything you have already answered is saved.
                </p>
              </.question_card>
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
          status={save_status(@alert)}
          show_delete?={not is_nil(@alert)}
          back_path={~p"/gtfs/#{@current_gtfs_version.id}/alerts"}
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

  # The status line says only what is true of this editor's own writes. Step 15
  # gives it the autosave wording as saves start to happen in the background.
  defp save_status(nil), do: "No alert saved yet."
  defp save_status(_alert), do: "Saved in this service version."
end
