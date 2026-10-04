defmodule GtfsPlannerWeb.Gtfs.TodsGeneratorLive do
  @moduledoc """
  The TODS generator page: the request, its preview, the save and its recovery.

  It states what the tool does to the selected version before offering a control,
  names its one prerequisite — an existing garage in this organization — and holds
  the five business inputs of a request: the inclusive date range, the Monday
  representative week, the fallback garage and the opt-in terminal relief. The
  dates default to the feed's first active calendar week and a single garage is
  preselected, because one garage is not a choice. The rules the generation would
  keep are shown read-only from the version's stored crew settings, with the Runs
  page named as their owner.

  Preview is one asynchronous read: the page hands those five inputs to
  `Gtfs.preview_tods_generation/2` and renders the candidate it answers with — the
  counts, the assumptions the plan rests on, the recurring dates a saved roster
  change would reach and the work it would leave out. Nothing is written, and the
  input revision the read was started for decides whether its answer still belongs
  to the form on screen.

  Save is one asynchronous write of the *stored* preview: the page keeps the
  preview's normalized input and source fingerprint in its own state and never
  accepts a candidate, an actor, an organization or a version from the browser. A
  request token is minted once per distinct input and put in the URL beside the
  request's own values, so refreshing recovers a completed request through
  `Gtfs.get_tods_generation/2` instead of generating twice. The token is a recovery
  key, never an authorization: the facade authorizes and scopes every read and
  write from the mount context.

  The page is reached from the account menu and guarded by the same editor role the
  other GTFS pages use; the menu is never the access check. It composes no planning
  data: the request is validated through `TodsGenerator.Input`, a garage the
  organization does not own is never echoed back as a choice, and the candidate the
  request describes stays the generator's own read.
  """

  use GtfsPlannerWeb, :live_view

  require Logger

  import GtfsPlannerWeb.PlannerComponents,
    only: [aside_link: 1, form_error_summary: 1, form_section: 1, message: 1, scope_line: 1]

  # The stored crew rules are rendered through the wording their own page already
  # owns, so this page never respells a rule the crew drawer states.
  import GtfsPlannerWeb.Gtfs.RunsComponents, only: [crew_rule_text: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.TodsGeneration
  alias GtfsPlanner.Gtfs.TodsGenerator.Input
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @generator_path "/tods-generator"
  @form_id "tods-generator-form"
  @form_error_id "tods-generator-form-error"

  # The request the URL carries so a refresh can recover it: the token the save is
  # keyed by, plus the five business inputs that produced the preview. The values
  # are parsed back through `Input` and are never authority; the token only ever
  # names a request the facade's own audit scope already authorizes.
  @request_param "request"
  # The four inputs whose name is already URL-shaped; terminal relief is written as
  # `terminal_relief` so the URL reads plainly and mapped back to the input's field.
  @query_keys ~w(start_date end_date representative_week garage_id)
  @relief_key "terminal_relief"

  # The request's controls in the order the form reads them, with the id each one
  # renders: a refused submit's summary links to the control its message names.
  @fields [
    start_date: "tods-start-date",
    end_date: "tods-end-date",
    representative_week: "tods-representative-week",
    garage_id: "tods-garage-select"
  ]

  @field_labels %{
    start_date: "First date",
    end_date: "Last date",
    representative_week: "Representative week",
    garage_id: "Fallback garage"
  }

  # How many dates or reasons a panel names before it counts the rest. The preview
  # is a summary, so it shows a representative few and the total beside them rather
  # than an unbounded list of every date a recurring slot reaches.
  @sample_size 5

  # What the page says when the organization has no garage to start from. It is a
  # state rather than a failure, so it is announced politely instead of alerting.
  @missing_garages_status %{
    kind: "warning",
    role: "status",
    title: "Add a garage first.",
    body:
      "Generation places vehicles and operators at the garages you entered, and this organization has none yet."
  }

  # The plan's own assumptions, in the operator's terms. The generator reports the
  # atoms; this page is the copy that explains what each one means for the result.
  @assumptions %{
    terminal_relief_additive:
      "A handover at a terminal stop is hypothetical and additive: no stored relief choice and no piece limit is changed to make work fit.",
    one_operator_per_run_day:
      "One fictional operator is created per run and weekday, which deliberately overstaffs the example instead of packing a weekly duty.",
    recurring_beyond_range:
      "A roster change repeats by weekday, so a saved slot reaches matching dates outside the dates you selected."
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "TODS generator")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:form_id, @form_id)
     |> assign(:form_error_id, @form_error_id)
     |> assign(:garages, [])
     |> assign(:active_dates, [])
     |> assign(:crew_rules, nil)
     |> assign(:failures, [])
     |> assign(:status, nil)
     |> assign(:form, nil)
     |> assign(:preview, nil)
     |> assign(:preview_revision, 0)
     |> assign(:preview_running, false)
     |> assign(:preview_error, nil)
     |> assign(:request_token, nil)
     |> assign(:request_input, nil)
     |> assign(:retry_save?, false)
     |> assign(:save_task, nil)
     |> assign(:save_error, nil)
     |> assign(:receipt, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    request_id = params[@request_param]

    cond do
      is_nil(request_id) ->
        {:noreply, load_page(socket)}

      # A save this page started put the token in the URL; the patch that carries it
      # back is not a refresh, so it must not re-read or replace the running state.
      socket.assigns.save_task != nil ->
        {:noreply, socket}

      # The request already answered the page: a repeated patch of the same URL
      # changes nothing, and the receipt stays on screen.
      receipt_for?(socket, request_id) ->
        {:noreply, socket}

      true ->
        {:noreply, recover_request(socket, request_id, params)}
    end
  end

  @impl true
  def handle_event("validate_request", %{"input" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(request_changeset(socket, params)))}
  end

  def handle_event("validate_request", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("preview_generation", %{"input" => params}, socket) do
    changeset = request_changeset(socket, params)

    cond do
      # The prerequisite is re-read here rather than trusted from the mount: a
      # control the browser disabled is not a server-side check, and a garage may
      # have been added or removed since the page opened.
      missing_garages?(socket) ->
        {:noreply,
         socket
         |> supersede_preview()
         |> assign(:form, to_form(changeset))
         |> assign(:failures, [])
         |> assign(:status, @missing_garages_status)}

      changeset.valid? ->
        {:noreply, start_preview(socket, changeset)}

      true ->
        {:noreply,
         socket
         |> supersede_preview()
         |> assign(:form, to_form(changeset))
         |> assign(:failures, failures(changeset))
         |> assign(:status, nil)
         |> push_event("focus_form_error", %{
           form_id: @form_id,
           fallback_id: @form_error_id
         })}
    end
  end

  def handle_event("preview_generation", _params, socket), do: {:noreply, socket}

  # The one save of the preview on screen. A second event while one is committing is
  # ignored rather than queued: the page keeps at most one current save, and the
  # only way a repeated request reaches the generator is the same token, which
  # answers with the receipt it already has.
  @impl true
  def handle_event("save_generation", _params, socket) do
    preview = socket.assigns.preview
    request_id = socket.assigns.request_token

    cond do
      is_nil(preview) or is_nil(request_id) ->
        {:noreply, socket}

      socket.assigns.save_task != nil or match?(%TodsGeneration{}, socket.assigns.receipt) ->
        {:noreply, socket}

      not preview.result.save_available? ->
        {:noreply, assign(socket, :save_error, unavailable_save_status(preview.result))}

      true ->
        {:noreply, start_save(socket, preview, request_id)}
    end
  end

  # A version switch keeps this page, because the page belongs to the version it
  # names: the new version's own ranges, garages and rules are what it must show.
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      {:noreply, push_navigate(socket, to: generator_path(version_id))}
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
      {:noreply, push_navigate(socket, to: generator_path(version_id))}
    else
      {:noreply, socket}
    end
  end

  # The preview read's own answer. The revision the read was started for decides
  # whether it still belongs to the form on screen: an answer for an input that has
  # since been replaced is discarded, exit included.
  @impl true
  def handle_async(
        {:preview, revision},
        result,
        %{assigns: %{preview_revision: revision}} = socket
      ) do
    {:noreply, socket |> assign(:preview_running, false) |> classify_preview(result)}
  end

  def handle_async({:preview, _superseded}, _result, socket), do: {:noreply, socket}

  # The save's own answer, matched by the task this page is waiting on. A result for
  # a task the page has already superseded — a new preview, a retry, a second tab —
  # changes nothing here, and it is never reported as a cancellation.
  @impl true
  def handle_info({ref, result}, socket) do
    if socket.assigns.save_task && socket.assigns.save_task.ref == ref do
      socket = assign(socket, :save_task, nil)
      {:noreply, classify_save(socket, result)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    if socket.assigns.save_task && socket.assigns.save_task.ref == ref do
      Logger.error("TODS generation save task exited: #{inspect(reason)}")
      {:noreply, classify_save(assign(socket, :save_task, nil), {:error, :write_failed})}
    else
      {:noreply, socket}
    end
  end

  defp generator_path(version_id), do: "/gtfs/#{version_id}#{@generator_path}"

  # --- the preview read -------------------------------------------------------

  defp start_preview(socket, changeset) do
    audit = AuditContext.from_assigns(socket.assigns)
    params = input_values(changeset)
    socket = supersede_preview(socket)
    revision = socket.assigns.preview_revision

    socket
    |> assign(:form, to_form(changeset))
    |> assign(:failures, [])
    |> assign(:status, nil)
    |> assign(:preview_running, true)
    |> start_async({:preview, revision}, fn -> Gtfs.preview_tods_generation(audit, params) end)
  end

  # A new request supersedes whatever the page held: the old preview is no longer
  # the input on screen, so it is dropped along with the form's refusals and the
  # revision moves on, which is what discards a late answer from the read it
  # replaces. A save that was running for it is forgotten here — its task keeps
  # running, and its answer is discarded rather than reported as a cancellation.
  defp supersede_preview(socket) do
    socket
    |> assign(:preview_revision, socket.assigns.preview_revision + 1)
    |> assign(:preview, nil)
    |> assign(:preview_running, false)
    |> assign(:preview_error, nil)
    |> assign(:save_task, nil)
    |> assign(
      :save_error,
      if(socket.assigns.retry_save?, do: socket.assigns.save_error, else: nil)
    )
    |> assign(:receipt, nil)
  end

  defp classify_preview(socket, {:ok, {:ok, preview}}) do
    token = retain_or_mint_token(socket, preview.normalized_inputs)

    assign(socket,
      preview: %{
        result: preview,
        normalized_inputs: preview.normalized_inputs,
        source_fingerprint: preview.source_fingerprint,
        request_id: token
      },
      preview_error: nil,
      request_token: token,
      request_input: preview.normalized_inputs
    )
  end

  defp classify_preview(socket, {:ok, {:error, %Ecto.Changeset{} = changeset}}) do
    socket
    |> assign(:failures, failures(changeset))
    |> assign(:preview_error, nil)
    |> push_event("focus_form_error", %{form_id: @form_id, fallback_id: @form_error_id})
  end

  defp classify_preview(socket, {:ok, {:error, reason}}) do
    assign(socket, :preview_error, preview_failure(reason))
  end

  defp classify_preview(socket, {:exit, reason}) do
    Logger.error("TODS generation preview task exited: #{inspect(reason)}")

    assign(socket, :preview_error, %{
      kind: "error",
      role: "alert",
      title: "The preview could not be built.",
      body: "Nothing was saved. Preview again, or try a smaller date range."
    })
  end

  defp retain_or_mint_token(socket, normalized_inputs) do
    if socket.assigns.request_token && socket.assigns.request_input == normalized_inputs do
      socket.assigns.request_token
    else
      Ecto.UUID.generate()
    end
  end

  defp preview_failure(:forbidden) do
    %{
      kind: "error",
      role: "alert",
      title: "You no longer have permission to generate here.",
      body: "Ask an organization administrator to restore your editor access."
    }
  end

  defp preview_failure(:not_found) do
    %{
      kind: "error",
      role: "alert",
      title: "This version is not available for generation.",
      body: "Choose a published version of this organization and try again."
    }
  end

  defp preview_failure(:missing_garages), do: @missing_garages_status

  defp preview_failure({:too_large, count}) do
    %{
      kind: "error",
      role: "alert",
      title: "The schedule is too large to generate from.",
      body:
        "These dates hold #{Wording.count_noun(count, "trip")}, above the bound this tool admits. " <>
          "Choose a shorter date range."
    }
  end

  # The read boundary's own refusals, which `Export.with_read_snapshot/1` answers
  # outside the plan's: its transaction deadline, and the rollback it reports on
  # the same boundary.
  defp preview_failure(:snapshot_timeout) do
    %{
      kind: "error",
      role: "alert",
      title: "The preview could not be read in time.",
      body: "Nothing was saved. Try a shorter date range, or preview again."
    }
  end

  defp preview_failure(:rollback) do
    %{
      kind: "error",
      role: "alert",
      title: "The preview read was rolled back.",
      body: "Nothing was saved. Preview again, or try a smaller date range."
    }
  end

  # No live read refusal this page does not name is a crash: the read answers with
  # whatever its own boundary refused, so the last clause states the generic case.
  defp preview_failure(_reason) do
    %{
      kind: "error",
      role: "alert",
      title: "The preview could not be built.",
      body: "Nothing was saved. Preview again, or try a smaller date range."
    }
  end

  # --- the save ---------------------------------------------------------------

  defp start_save(socket, preview, request_id) do
    audit = AuditContext.from_assigns(socket.assigns)

    # The request is the stored preview's own: the input the preview normalized and
    # the fingerprint it compared. Nothing the browser submitted reaches the write.
    request = %{
      request_id: request_id,
      input: preview.normalized_inputs,
      source_fingerprint: preview.source_fingerprint
    }

    task =
      Task.Supervisor.async_nolink(GtfsPlanner.TaskSupervisor, fn ->
        Gtfs.apply_tods_generation(audit, request)
      end)

    socket
    |> assign(:save_task, task)
    |> assign(:save_error, nil)
    |> assign(:receipt, nil)
    |> push_patch(to: request_path(socket, request_id, preview.normalized_inputs))
  end

  # The request values go into the URL beside the token so a refresh has the same
  # input the preview ran on. They are parsed back through `Input` on the way in and
  # are never authority: the token names a request, and the audit scope authorizes.
  defp request_path(socket, request_id, normalized_inputs) do
    query =
      normalized_inputs
      |> Map.take(@query_keys)
      |> Map.put(@relief_key, Map.get(normalized_inputs, "terminal_relief?"))
      |> Map.put(@request_param, request_id)

    "/gtfs/#{socket.assigns.current_gtfs_version.id}#{@generator_path}?#{URI.encode_query(query)}"
  end

  defp classify_save(socket, {:ok, %TodsGeneration{} = receipt}) do
    socket
    |> assign(:receipt, receipt)
    |> assign(:save_error, nil)
    |> assign(:status, nil)
    |> assign(:retry_save?, false)
  end

  defp classify_save(socket, {:error, %Ecto.Changeset{} = changeset}) do
    socket
    |> assign(:failures, failures(changeset))
    |> assign(:save_error, nil)
    |> assign(:preview, nil)
    |> assign(:retry_save?, false)
    |> push_event("focus_form_error", %{form_id: @form_id, fallback_id: @form_error_id})
  end

  defp classify_save(socket, {:error, :stale_plan}) do
    socket
    |> assign(:preview, nil)
    |> assign(:retry_save?, false)
    |> assign(:save_error, %{
      kind: "warning",
      role: "status",
      title: "The schedule changed since this preview.",
      body:
        "Nothing was saved. Preview again: the preview reads the schedule as it is now, and saving writes only what that preview showed."
    })
  end

  defp classify_save(socket, {:error, reason}) do
    assign(socket, :save_error, save_failure(reason))
  end

  defp save_failure(:forbidden) do
    %{
      kind: "error",
      role: "alert",
      title: "You no longer have permission to save here.",
      body: "Nothing was saved. Ask an organization administrator to restore your editor access."
    }
  end

  defp save_failure(:not_found) do
    %{
      kind: "error",
      role: "alert",
      title: "This version is not available to save into.",
      body: "Nothing was saved. Choose a published version of this organization and try again."
    }
  end

  defp save_failure(:missing_garages) do
    %{
      kind: "warning",
      role: "status",
      title: "Add a garage first.",
      body:
        "Nothing was saved: generation places vehicles and operators at this organization's garages."
    }
  end

  defp save_failure({:too_large, count}) do
    %{
      kind: "error",
      role: "alert",
      title: "The schedule is too large to generate from.",
      body:
        "Nothing was saved: these dates now hold #{Wording.count_noun(count, "trip")}, above the " <>
          "bound this tool admits. Choose a shorter date range and preview again."
    }
  end

  defp save_failure(:request_conflict) do
    %{
      kind: "error",
      role: "alert",
      title: "This request was already completed with different input.",
      body: "Nothing was saved. Preview the input you want and save that."
    }
  end

  defp save_failure(:nothing_to_save) do
    %{
      kind: "warning",
      role: "status",
      title: "There is nothing left to add.",
      body:
        "Nothing was saved: the schedule already holds the work this request describes. " <>
          "Preview again to see what remains."
    }
  end

  defp save_failure(:busy) do
    %{
      kind: "warning",
      role: "status",
      title: "The schedule is busy right now.",
      body:
        "Nothing was saved after three attempts. Wait a moment, then save this preview again — " <>
          "the same request returns the generation it already completed."
    }
  end

  defp save_failure({:audit_failed, _reason}) do
    %{
      kind: "error",
      role: "alert",
      title: "Nothing was saved.",
      body: "The change log refused a record, so the whole generation was rolled back. Try again."
    }
  end

  defp save_failure(:write_failed) do
    %{
      kind: "error",
      role: "alert",
      title: "Nothing was saved.",
      body:
        "The save could not complete. Try again; a request that committed is never written twice."
    }
  end

  defp save_failure(_reason) do
    %{
      kind: "error",
      role: "alert",
      title: "Nothing was saved.",
      body: "The save could not complete. Try again."
    }
  end

  # A preview the save refused because it adds nothing to write.
  defp unavailable_save_status(%{no_work?: true} = preview) do
    %{
      kind: "warning",
      role: "status",
      title: "There is nothing to save from this preview.",
      body: no_work_body(preview)
    }
  end

  defp unavailable_save_status(_preview) do
    %{
      kind: "warning",
      role: "status",
      title: "This preview cannot be saved.",
      body:
        "Nothing was saved: the plan leaves a stored base-week choice it would have to change. " <>
          "Change the representative week and preview again."
    }
  end

  # Generating nothing has two causes, and the page may not confuse them: a range
  # with no service at all, and a schedule that already holds every piece of work
  # this request describes. The day types the range selects are what tells them
  # apart, because a range with service always selects at least one.
  defp no_work_title(%{day_type_keys: []}), do: "No service to staff in these dates"
  defp no_work_title(_preview), do: "Nothing left to add in these dates"

  defp no_work_body(%{day_type_keys: []}) do
    "This version has scheduled no service in the dates you selected, so there is nothing to" <>
      " generate. Choose a range with service."
  end

  defp no_work_body(_preview) do
    "The schedule already holds the work this request would describe, so saving it would add" <>
      " nothing. Existing blocks, runs and roster lines are kept as they are; preview other" <>
      " dates to see what they would add."
  end

  defp save_blocked_text(%{no_work?: true}),
    do: "Nothing to save: this request would add no work."

  defp save_blocked_text(_preview) do
    "This preview cannot be saved: a generation the plan leaves incomplete is not written" <>
      " part-way. Change the request and preview again."
  end

  # --- the URL's own request --------------------------------------------------

  # A refresh with the token in the URL asks the facade whether the request
  # completed, and never writes anything to find out. A request the scope no longer
  # authorizes is a permission state; a request with no receipt is explained, and
  # the page keeps the token so a fresh preview of the same input can retry it.
  defp recover_request(socket, request_id, params) do
    socket = load_page(socket)
    changeset = request_changeset(socket, query_input(params))

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:request_token, request_id)
      |> assign(:request_input, normalized_input(changeset))

    case Gtfs.get_tods_generation(AuditContext.from_assigns(socket.assigns), request_id) do
      {:ok, receipt} ->
        assign(socket, :receipt, receipt)

      {:error, :not_found} ->
        socket
        |> assign(:retry_save?, true)
        |> assign(:save_error, unknown_completion_status())

      {:error, :forbidden} ->
        assign(socket, :save_error, save_failure(:forbidden))
    end
  end

  defp unknown_completion_status do
    %{
      kind: "warning",
      role: "status",
      title: "This request has no completed generation.",
      body:
        "It may still be running, or it may never have reached the database. Nothing is reported " <>
          "as cancelled. Preview the request again, then save: Retry save reuses this request, so a " <>
          "generation that did complete is returned rather than written twice."
    }
  end

  defp receipt_for?(socket, request_id) do
    match?(%TodsGeneration{request_id: ^request_id}, socket.assigns.receipt)
  end

  defp load_page(socket) do
    organization = socket.assigns.current_organization
    version = socket.assigns.current_gtfs_version

    socket =
      socket
      |> assign(:garages, garages(organization.id))
      |> assign(:active_dates, active_dates(organization.id, version.id))
      |> assign(:crew_rules, Gtfs.get_crew_settings(organization.id, version.id))
      |> assign(:failures, [])
      |> assign(:status, nil)
      |> assign(:preview, nil)
      |> assign(:preview_error, nil)
      |> assign(:save_error, nil)
      |> assign(:receipt, nil)

    assign(socket, :form, to_form(request_changeset(socket, %{})))
  end

  defp garages(organization_id) do
    organization_id
    |> Operations.planning_garages()
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  # The same predicate the generator answers `:missing_garages` with, asked of the
  # stored rows rather than of a page assignment.
  defp missing_garages?(socket) do
    Operations.planning_garages(socket.assigns.current_organization.id) == %{}
  end

  # The feed's dates with scheduled service. The form's default week has to be the
  # week the generator itself would default to, so this is the same scope read
  # (`Calendars.list_calendars/2` filtered by the selected range) the generator's
  # source loader makes. A version whose calendars cannot be read has no dates to
  # offer, and the fields' own validation reports the missing ones.
  defp active_dates(organization_id, gtfs_version_id) do
    case Calendars.list_calendars(organization_id, gtfs_version_id) do
      {:ok, calendars} ->
        calendars |> Enum.flat_map(& &1.active_dates) |> Enum.uniq() |> Enum.sort()

      {:error, :not_found} ->
        []
    end
  end

  # The request the form holds. The dates come from the feed's first active week
  # and a single garage is preselected, because one garage is not a choice; a
  # `garage_id` this organization does not own is not a choice either, so it is
  # replaced with no choice rather than echoed back as if the reader had picked it.
  defp request_changeset(socket, params) do
    params =
      case Map.get(params, "garage_id") do
        garage_id when is_binary(garage_id) ->
          Map.put(params, "garage_id", own_garage_id(socket.assigns.garages, garage_id))

        _none ->
          preselect_only_garage(params, socket.assigns.garages)
      end

    Input.changeset(%Input{}, params, socket.assigns.active_dates)
  end

  defp own_garage_id(garages, garage_id) do
    if Enum.any?(garages, &(&1.id == garage_id)), do: garage_id, else: nil
  end

  defp preselect_only_garage(params, [garage]), do: Map.put(params, "garage_id", garage.id)
  defp preselect_only_garage(params, _garages), do: params

  # The five business inputs of a valid changeset, as strings the input owner
  # parses: the only values the page hands the generator.
  defp input_values(changeset) do
    input = Ecto.Changeset.apply_changes(changeset)

    %{
      "start_date" => Date.to_iso8601(input.start_date),
      "end_date" => Date.to_iso8601(input.end_date),
      "representative_week" => Date.to_iso8601(input.representative_week),
      "garage_id" => input.garage_id,
      "terminal_relief?" => input.terminal_relief?
    }
  end

  # The request values a URL carries, back in the input's own field names. They are
  # parsed through `Input` like any other submission and never trusted as authority.
  defp query_input(params) do
    input = Map.take(params, @query_keys)

    case Map.fetch(params, @relief_key) do
      {:ok, value} -> Map.put(input, "terminal_relief?", value)
      :error -> input
    end
  end

  defp normalized_input(changeset) do
    case Input.normalize(changeset) do
      {:ok, normalized} -> normalized
      {:error, _changeset} -> nil
    end
  end

  # Every problem at once, each linking to the control it names, in the order the
  # form reads.
  defp failures(changeset) do
    for {field, id} <- @fields,
        {message, _opts} <- Keyword.get_values(changeset.errors, field) do
      %{href: "##{id}", msg: "#{Map.fetch!(@field_labels, field)} #{message}."}
    end
  end

  # --- rendering the candidate ------------------------------------------------

  # Each figure is `{dom id, singular noun, count}`: the noun is pluralised from the
  # count where it is rendered, so "1 new block" and "25 new blocks" are the same
  # one entry.
  defp count_items(counts) do
    [
      {"blocks", "new block", counts.new_blocks},
      {"trips", "trip assigned", counts.new_assignments},
      {"runs", "run", counts.new_runs},
      {"lines", "roster line", counts.new_lines},
      {"operators", "fictional operator", counts.new_operators},
      {"open", "open run-day", counts.open_run_days}
    ]
  end

  defp kept_items(counts) do
    [
      {"blocks", "existing block", counts.preserved_blocks},
      {"lines", "existing line", counts.preserved_lines},
      {"slots", "existing slot", counts.preserved_slots},
      {"operators", "existing operator", counts.preserved_operators}
    ]
    |> Enum.reject(fn {_id, _noun, count} -> count == 0 end)
  end

  defp figure_text({_id, noun, count}), do: "#{count} #{Wording.noun(count, noun)}"

  # What the preview would leave out, grouped by the reason the plan reported, with
  # the number of pieces each reason accounts for.
  defp exclusion_items(preview) do
    trips =
      Enum.reduce(preview.exclusions, %{}, fn exclusion, acc ->
        Map.update(acc, exclusion.reason, 1, &(&1 + 1))
      end)

    run_days =
      Enum.reduce(preview.roster_exclusions, %{}, fn exclusion, acc ->
        Map.update(acc, exclusion.reason, 1, &(&1 + 1))
      end)

    (Enum.map(trips, fn {reason, count} ->
       {reason, count, "trip", trip_exclusion_text(reason)}
     end) ++
       Enum.map(run_days, fn {reason, count} ->
         {reason, count, "run-day", run_day_exclusion_text(reason)}
       end))
    |> Enum.sort_by(fn {reason, _count, _noun, _text} -> to_string(reason) end)
  end

  # Each reason's own phrase, written to read after its count's noun: "3 trips on a
  # repeating service", "1 run-day with no base weekday to repeat from".
  defp trip_exclusion_text(:repeating_service), do: "on a repeating service"
  defp trip_exclusion_text(:unplottable), do: "that the schedule cannot plot"
  defp trip_exclusion_text(:unknown_location), do: "with no known location"
  defp trip_exclusion_text(:exceeds_vehicle_limit), do: "beyond the vehicle piece limit"
  defp trip_exclusion_text(:exceeds_relief_limit), do: "beyond the relief limit"
  defp trip_exclusion_text(reason), do: "left out (#{reason})"

  defp run_day_exclusion_text(:no_base_weekday), do: "with no base weekday to repeat from"
  defp run_day_exclusion_text(:run_has_errors), do: "whose run has an error"
  defp run_day_exclusion_text(:stale_slot), do: "held by a slot the exporter drops"
  defp run_day_exclusion_text(reason), do: "left out (#{reason})"

  # The phrases a count cannot say on its own: "no date" rather than "0 dates".
  defp open_dates_text(0), do: "No selected date stays open."
  defp open_dates_text(1), do: "1 selected date stays open."
  defp open_dates_text(count), do: "#{count} selected dates stay open."

  defp different_service_text(0) do
    "No date in this calendar runs a different service, such as a holiday Monday, so" <>
      " no date is left unstaffed for that reason."
  end

  defp different_service_text(1) do
    "1 date runs a different service, such as a holiday Monday, and is not staffed by" <>
      " this recurring change."
  end

  defp different_service_text(count) do
    "#{count} dates run a different service, such as a holiday Monday, and are not" <>
      " staffed by this recurring change."
  end

  defp beyond_range_text(0), do: "none of them outside the dates you selected"
  defp beyond_range_text(1), do: "1 of them outside the dates you selected"
  defp beyond_range_text(count), do: "#{count} of them outside the dates you selected"

  defp warning_count(preview), do: length(preview.warnings)

  defp sample(dates) do
    case Enum.split(dates, @sample_size) do
      {shown, []} -> {shown, 0}
      {shown, rest} -> {shown, length(rest)}
    end
  end

  defp sample_dates_text([]), do: ""

  defp sample_dates_text(dates) do
    {shown, remaining} = sample(dates)
    text = Enum.map_join(shown, ", ", &Wording.short_date/1)

    if remaining == 0, do: text, else: "#{text} and #{remaining} more"
  end

  defp assumption_text(assumption), do: Map.get(@assumptions, assumption, to_string(assumption))

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
      <div id="tods-generator-page" phx-hook="FormErrorFocus" class="ds-page">
        <.header>
          TODS generator
          <:subtitle>
            Builds fictional operating data from a schedule, for internal testing and
            demonstrations.
            <.scope_line id="tods-generator-scope" icon="hero-beaker">
              Builds into {@current_gtfs_version.name} at {@current_organization.name}. Fictional
              operators belong to {@current_organization.name}, so they appear on this
              organization's Rosters page for every version.
            </.scope_line>
          </:subtitle>
        </.header>

        <section
          id="tods-generator-purpose"
          aria-labelledby="tods-generator-purpose-title"
          class="mt-6 max-w-3xl rounded-card border border-subtle bg-white px-5 py-5 sm:px-6"
        >
          <h2
            id="tods-generator-purpose-title"
            class="font-display text-[19px] font-semibold tracking-[-0.02em] text-strong"
          >
            Generate fictional operations data
          </h2>
          <p class="mt-2 text-sm text-default">
            Use this tool to populate GTFS Planner for internal testing and demonstrations. It
            creates made-up operating assignments and operators from this version's schedule and
            your existing garages. The results are planning examples, not an agency's actual
            staffing plan.
          </p>
          <p class="mt-3 text-sm text-default">
            Saving adds data to the Blocks, Runs and Rosters screens of {@current_gtfs_version.name}.
            Fictional operators are saved for the organization and appear in its Operators list
            beside its real ones. Existing assignments are kept; the preview shows what would be
            added and any work it leaves uncovered. Saved data can be edited on those screens and
            is included in later TODS exports. Generating does not publish a feed.
          </p>
          <p class="mt-3 text-sm text-default">
            A roster change repeats by weekday, so a saved slot affects every matching date in the
            calendar — including matching dates after the range you select here. Dates whose
            service differs, such as holidays, stay uncovered.
          </p>
        </section>

        <.message
          :if={@garages == []}
          id="tods-generator-missing-garages"
          kind="warning"
          title="Add a garage first"
          class="mt-6 max-w-3xl"
        >
          Generation places vehicles and operators at garages you entered. This organization has
          none yet, so there is nothing to build from.
          <:action>
            <.button
              id="tods-generator-garages-link"
              variant="secondary"
              class="min-h-11"
              navigate={~p"/gtfs/#{@current_gtfs_version.id}/settings/garages"}
            >
              Open Settings › Garages
            </.button>
          </:action>
        </.message>

        <.message
          :if={@status}
          id="tods-generator-status"
          kind={@status.kind}
          role={@status.role}
          title={@status.title}
          class="mt-6 max-w-3xl"
        >
          {@status.body}
        </.message>

        <.form_error_summary
          id={@form_error_id}
          title="The request needs fixing"
          failures={@failures}
          class="mt-6 max-w-3xl mb-0"
        />

        <.form
          for={@form}
          id={@form_id}
          novalidate
          phx-change="validate_request"
          phx-submit="preview_generation"
          class="mt-6 max-w-3xl overflow-hidden rounded-card border border-subtle bg-white"
        >
          <div class="grid gap-6 p-5 sm:p-6">
            <.form_section title="Service scope" first?>
              <div class="grid gap-4 sm:grid-cols-3">
                <.input
                  field={@form[:start_date]}
                  type="date"
                  id="tods-start-date"
                  label="First date"
                />
                <.input field={@form[:end_date]} type="date" id="tods-end-date" label="Last date" />
                <.input
                  field={@form[:representative_week]}
                  type="date"
                  id="tods-representative-week"
                  label="Representative week"
                />
              </div>
              <p class="text-[13px] text-muted">
                The first date defaults to the feed's first active calendar week. The dates are
                inclusive, and the representative week is a whole Monday-to-Sunday week inside
                them: its weekday pattern is what a saved roster line repeats.
              </p>
            </.form_section>

            <.form_section title="Garage">
              <.input
                field={@form[:garage_id]}
                type="select"
                id="tods-garage-select"
                label="Fallback garage"
                prompt="Choose a garage"
                disabled={@garages == []}
                options={Enum.map(@garages, &{&1.name, &1.id})}
              />
              <p class="text-[13px] text-muted">
                Blocks use this garage only where no existing block, block attribute, route
                setting or default already resolves one. The list is every garage {@current_organization.name} has entered.
              </p>
            </.form_section>

            <.form_section title="Terminal relief">
              <.input
                field={@form[:terminal_relief?]}
                type="checkbox"
                id="tods-terminal-relief"
                label="Allow handovers at a terminal stop"
              />
              <p id="tods-terminal-relief-consequence" class="mt-1 text-[13px] text-muted">
                Adds a handover at a terminal stop only where an existing relief window already
                allows one. No limit is relaxed to make work fit, and any setting this adds is
                shown in the preview before it is saved.
              </p>
            </.form_section>

            <.form_section title="Rules in force">
              <p id="tods-generator-rules" class="text-sm text-default">
                {crew_rule_text(@crew_rules)}
              </p>
              <p id="tods-generator-rules-spread" class="mt-1 text-sm text-default">
                Longest spread: {div(@crew_rules.max_spread_minutes, 60)} h.
              </p>
              <p class="mt-2 text-[13px] text-muted">
                These are {@current_gtfs_version.name}'s stored crew rules. Generation keeps them
                as they are; change them where they are owned.
              </p>
              <.aside_link
                id="tods-generator-rules-link"
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/runs"}
              >
                Crew rules on Runs
              </.aside_link>
            </.form_section>
          </div>

          <div class="flex flex-wrap items-center justify-end gap-3 border-t border-subtle px-5 py-4 sm:px-6">
            <p
              :if={@garages == []}
              id="tods-preview-blocked"
              class="basis-full text-[13px] text-muted sm:mr-auto sm:basis-auto"
            >
              Add a garage before previewing a generation.
            </p>
            <.button
              type="submit"
              id="tods-preview-button"
              class="min-h-11"
              disabled={@garages == []}
              data-unavailable={@garages == []}
            >
              Preview generation
            </.button>
          </div>
        </.form>

        <.message
          :if={@preview_running}
          id="tods-preview-running"
          kind="info"
          role="status"
          title="Building the preview…"
          class="mt-6 max-w-3xl"
        >
          Reading this version's schedule and rules. Nothing is saved.
        </.message>

        <.message
          :if={@preview_error}
          id="tods-preview-error"
          kind={@preview_error.kind}
          role={@preview_error.role}
          title={@preview_error.title}
          class="mt-6 max-w-3xl"
        >
          {@preview_error.body}
        </.message>

        <.message
          :if={@save_error}
          id="tods-save-status"
          kind={@save_error.kind}
          role={@save_error.role}
          title={@save_error.title}
          class="mt-6 max-w-3xl"
        >
          {@save_error.body}
        </.message>

        <.message
          :if={@save_task}
          id="tods-save-running"
          kind="info"
          role="status"
          title="Saving this generation…"
          class="mt-6 max-w-3xl"
        >
          Writing the blocks, runs, roster lines and fictional operators in one transaction. This
          page cannot cancel a save once it has started.
        </.message>

        <section
          :if={@receipt}
          id="tods-generation-result"
          role="status"
          aria-labelledby="tods-generation-result-title"
          class="mt-6 max-w-3xl rounded-card border border-subtle bg-white px-5 py-5 sm:px-6"
        >
          <h2
            id="tods-generation-result-title"
            class="font-display text-[19px] font-semibold tracking-[-0.02em] text-strong"
          >
            Generation saved
          </h2>
          <p id="tods-result-identifier" class="mt-1 text-[13px] text-muted">
            Request {short_id(@receipt.request_id)} · receipt {short_id(@receipt.id)}
          </p>
          <p class="mt-3 text-sm text-default">
            Saved to {@current_gtfs_version.name} at {@current_organization.name}. A repeated save of
            this request returns this same receipt instead of adding the data twice.
          </p>

          <div id="tods-result-counts" class="mt-4 grid gap-x-6 gap-y-2 sm:grid-cols-3">
            <p
              :for={item <- saved_items(@receipt)}
              id={"tods-result-count-" <> elem(item, 0)}
              class="text-sm"
            >
              <span class="font-semibold text-strong">{elem(item, 2)}</span><span class="text-muted">{" " <> Wording.noun(elem(item, 2), elem(item, 1))}</span>
            </p>
          </div>

          <div :if={@preview} id="tods-result-notes" class="mt-4 grid gap-2 text-[13px] text-muted">
            <ul :if={@preview.result.assumptions != []} id="tods-result-assumptions">
              <li
                :for={assumption <- @preview.result.assumptions}
                id={"tods-result-assumption-" <> to_string(assumption)}
              >
                {assumption_text(assumption)}
              </li>
            </ul>
            <p :if={warning_count(@preview.result) > 0} id="tods-result-warnings">
              {Wording.count_noun(warning_count(@preview.result), "warning")} from the crew checks sit on the saved runs.
            </p>
            <ul :if={exclusion_items(@preview.result) != []} id="tods-result-exclusions">
              <li
                :for={{reason, count, noun, text} <- exclusion_items(@preview.result)}
                id={"tods-result-exclusion-" <> to_string(reason)}
              >
                {Wording.count_noun(count, noun)} {text}.
              </li>
            </ul>
          </div>

          <div class="mt-5 flex flex-wrap gap-2">
            <.aside_link
              id="tods-result-blocks"
              navigate={~p"/gtfs/#{@current_gtfs_version.id}/blocks"}
            >
              Blocks
            </.aside_link>
            <.aside_link id="tods-result-runs" navigate={~p"/gtfs/#{@current_gtfs_version.id}/runs"}>
              Runs
            </.aside_link>
            <.aside_link
              id="tods-result-rosters"
              navigate={~p"/gtfs/#{@current_gtfs_version.id}/rosters"}
            >
              Rosters
            </.aside_link>
            <.aside_link
              id="tods-result-operators"
              navigate={~p"/gtfs/#{@current_gtfs_version.id}/rosters"}
            >
              Operators
            </.aside_link>
            <.aside_link
              id="tods-result-export"
              navigate={~p"/gtfs/#{@current_gtfs_version.id}/export?#{[type: "operations"]}"}
            >
              Export operations
            </.aside_link>
          </div>
          <p id="tods-result-operators-note" class="mt-3 text-[13px] text-muted">
            Fictional operators are organization-wide. On the Rosters page, open the existing
            Operators control (its label starts with “Operators ·”) to see them beside the real ones.
          </p>
        </section>

        <section
          :if={@preview && is_nil(@receipt)}
          id="tods-generation-preview"
          aria-labelledby="tods-generation-preview-title"
          class="mt-6 max-w-3xl rounded-card border border-subtle bg-white px-5 py-5 sm:px-6"
        >
          <h2
            id="tods-generation-preview-title"
            class="font-display text-[19px] font-semibold tracking-[-0.02em] text-strong"
          >
            Preview — nothing saved yet
          </h2>
          <p id="tods-preview-range" class="mt-1 text-sm text-default">
            Dates {Wording.date(@preview.result.coverage.range.start_date)} to {Wording.date(
              @preview.result.coverage.range.end_date
            )}, representative week from {Wording.date(
              @preview.result.coverage.range.representative_week
            )}.
          </p>

          <.message
            :if={@preview.result.no_work?}
            id="tods-preview-no-work"
            kind="warning"
            role="status"
            title={no_work_title(@preview.result)}
            class="mt-4"
          >
            {no_work_body(@preview.result)}
          </.message>

          <div
            :if={not @preview.result.no_work?}
            id="tods-preview-counts"
            class="mt-4 grid gap-x-6 gap-y-2 sm:grid-cols-3"
          >
            <p
              :for={item <- count_items(@preview.result.counts)}
              id={"tods-preview-count-" <> elem(item, 0)}
              class="text-sm"
            >
              <span class="font-semibold text-strong">{elem(item, 2)}</span><span class="text-muted">{" " <> Wording.noun(elem(item, 2), elem(item, 1))}</span>
            </p>
          </div>

          <p
            :if={not @preview.result.no_work? and kept_items(@preview.result.counts) != []}
            id="tods-preview-kept"
            class="mt-3 text-[13px] text-muted"
          >
            Kept as they are: {kept_text(@preview.result.counts)}.
          </p>

          <div :if={not @preview.result.no_work?} class="mt-4 grid gap-2 text-sm text-default">
            <p id="tods-preview-staffed">
              A saved roster change repeats by weekday, so it reaches {Wording.count_noun(
                length(@preview.result.coverage.affected_dates),
                "date"
              )}, {beyond_range_text(length(@preview.result.coverage.beyond_range_dates))}.
              <span :if={@preview.result.coverage.beyond_range_dates != []} class="text-muted">
                Beyond the range: {sample_dates_text(@preview.result.coverage.beyond_range_dates)}.
              </span>
            </p>
            <p id="tods-preview-open">
              {open_dates_text(length(@preview.result.coverage.open_dates))}
              <span :if={@preview.result.coverage.open_dates != []} class="text-muted">
                Open: {sample_dates_text(@preview.result.coverage.open_dates)}.
              </span>
            </p>
            <p id="tods-preview-other-service">
              {different_service_text(length(@preview.result.coverage.other_service_dates))}
            </p>
          </div>

          <div :if={@preview.result.assumptions != []} class="mt-4" id="tods-preview-assumptions">
            <h3 class="text-sm font-semibold text-strong">What this preview assumes</h3>
            <ul class="mt-1 grid gap-1 text-[13px] text-muted">
              <li
                :for={assumption <- @preview.result.assumptions}
                id={"tods-preview-assumption-" <> to_string(assumption)}
              >
                {assumption_text(assumption)}
              </li>
            </ul>
          </div>

          <div :if={exclusion_items(@preview.result) != []} class="mt-4" id="tods-preview-exclusions">
            <h3 class="text-sm font-semibold text-strong">Left out of this generation</h3>
            <ul class="mt-1 grid gap-1 text-[13px] text-muted">
              <li
                :for={{reason, count, noun, text} <- exclusion_items(@preview.result)}
                id={"tods-preview-exclusion-" <> to_string(reason)}
              >
                {Wording.count_noun(count, noun)} {text}.
              </li>
            </ul>
          </div>

          <div class="mt-5 flex flex-wrap items-center justify-end gap-3 border-t border-subtle pt-4">
            <p
              :if={not @preview.result.save_available?}
              id="tods-save-blocked"
              class="basis-full text-[13px] text-muted sm:mr-auto sm:basis-auto"
            >
              {save_blocked_text(@preview.result)}
            </p>
            <.button
              type="button"
              phx-click="save_generation"
              id="tods-save-button"
              class="min-h-11"
              disabled={not @preview.result.save_available? or @save_task != nil}
              data-unavailable={not @preview.result.save_available?}
            >
              {save_button_label(@retry_save?)}
            </.button>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp save_button_label(true), do: "Retry save"
  defp save_button_label(false), do: "Save generation"

  defp saved_items(receipt) do
    [
      {"blocks", "block", summary_count(receipt, "blocks")},
      {"trips", "trip moved", summary_count(receipt, "changed_trips")},
      {"runs", "run", summary_count(receipt, "runs")},
      {"lines", "roster line", summary_count(receipt, "lines")},
      {"slots", "roster slot", summary_count(receipt, "slots")},
      {"operators", "fictional operator", summary_count(receipt, "operators")}
    ]
  end

  defp summary_count(receipt, key), do: Map.get(receipt.summary, key, 0)

  defp kept_text(counts) do
    counts |> kept_items() |> Enum.map_join(", ", &figure_text/1)
  end

  defp short_id(uuid) when is_binary(uuid), do: binary_part(uuid, 0, 8)
  defp short_id(_id), do: "unknown"
end
