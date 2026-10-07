defmodule GtfsPlannerWeb.Gtfs.CompareLive do
  @moduledoc """
  LiveView for comparing two retained full feed exports.

  Requires pathways_studio_editor role. `CompareLive` owns the comparison events
  and data; `GtfsPlannerWeb.Gtfs.CompareComponents` renders the comparison
  surface. The page mounts only the release-comparison helper.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.ReleaseComparison
  alias GtfsPlanner.Gtfs.ReleaseComparison.AssistantContext
  alias GtfsPlanner.Gtfs.ReleaseComparison.Compare
  alias GtfsPlannerWeb.AgentPanel
  alias GtfsPlannerWeb.Gtfs.ComparePresentation
  alias GtfsPlannerWeb.GtfsVersionNavigation

  import GtfsPlannerWeb.AgentComponents, only: [agent_panel: 1]

  import GtfsPlannerWeb.Gtfs.CompareComponents,
    only: [
      comparison: 1,
      comparison_helper: 1,
      comparison_results: 1,
      comparison_structural_row: 1,
      comparison_unknown_row: 1,
      comparison_unresolved_row: 1
    ]

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # One page of retained full feed files the editor can choose from. The chosen
  # identities are kept server-side, so a selection made on one page survives
  # the next page load and is never taken from a submitted value.
  @comparison_page_size 25

  # One page of a bounded native result. The result itself is never replaced by
  # its page: only the rows the page renders are sliced, so a native result
  # stays fully inspectable however many rows it holds.
  @comparison_row_limit 25
  @comparison_row_limit_max 100
  @comparison_collections [
    :comparison_structural,
    :comparison_unresolved,
    :comparison_unknowns
  ]
  @comparison_scope_notice "Choose at least one route and one date to narrow this comparison."
  @comparison_scope_invalid_notice "Those routes or dates aren’t part of this comparison."

  # The change kinds a kind chip may filter to. An unknown value is ignored, so
  # a forged event can never name a kind this page does not render.
  @comparison_change_kinds [:added, :removed, :count_changed, :timing_changed, :frequency_changed]

  @comparison_unavailable_notice "Those exports aren’t available to compare."
  @comparison_window_notice "Enter both dates, with the last date on or after the first."
  @comparison_profile_notice "Only full feed exports can be compared."
  @comparison_start_failed_notice "The comparison couldn’t start. Try again."

  @comparison_reason_notices %{
    unavailable: @comparison_unavailable_notice,
    invalid_window: @comparison_window_notice,
    unsupported_profile: @comparison_profile_notice,
    unsupported_size: "Those exports are larger than a comparison can read.",
    malformed_csv:
      "One of those files has a table that isn’t valid CSV, so nothing was compared.",
    invalid_archive: "One of those files isn’t a readable feed archive, so nothing was compared.",
    cancelled: "The comparison was cancelled. Nothing in your feed was changed.",
    timeout: "The comparison took longer than its time limit and stopped.",
    worker_exit: "The comparison stopped unexpectedly. Nothing in your feed was changed."
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Compare files")
     |> assign(:user_roles, user_roles)
     |> assign(:comparison_form, comparison_form(%{}))
     |> assign(:comparison_choices, %{rows: [], next_cursor: nil})
     |> assign(:comparison_cursor, nil)
     |> assign(:comparison_chosen, %{left: nil, right: nil})
     |> assign(:comparison_status, :idle)
     |> assign(:comparison_notice, nil)
     |> assign(:comparison_request_ref, nil)
     |> assign(:comparison_fingerprint, nil)
     |> assign(:comparison_coordinator, nil)
     |> assign(:comparison_monitor, nil)
     |> assign(:comparison_result, nil)
     |> assign_comparison_view(nil)
     |> assign(:comparison_scope, nil)
     |> assign(:comparison_scope_form, comparison_scope_form(%{}))
     |> assign(:comparison_scope_notice, nil)
     |> assign(:comparison_inspected, nil)
     |> assign(:comparison_inspected_route, nil)
     |> assign(:comparison_page, comparison_page_defaults())
     |> assign(:comparison_true_totals, Map.new(@comparison_collections, &{&1, 0}))
     |> AgentPanel.mount("release_comparison", allowed_packs: ["release_comparison"])
     |> reset_comparison_context()
     |> configure_comparison_streams()
     |> stream(:comparison_structural, [])
     |> stream(:comparison_unresolved, [])
     |> stream(:comparison_unknowns, [])}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    ExportRuns.reconcile_expired(organization_id)
    ExportRuns.cleanup_expired(organization_id)

    socket =
      socket
      |> reset_comparison_on_version_change()
      |> load_comparison_choices()
      |> initialize_comparison_defaults(params)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         GtfsVersionNavigation.published_for_current_organization?(socket, version_id) do
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/compare")}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if GtfsVersionNavigation.published_for_current_organization?(socket, version_id) do
      # Push event to JS hook to update localStorage
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      # Navigate to new version
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/compare")}
    else
      {:noreply, socket}
    end
  end

  # Opening from the finished comparison binds the comparison helper first, so the
  # panel never opens without an admitted copy. With no context the event changes
  # nothing; the panel's only helper is the comparison helper.
  @impl Phoenix.LiveView
  def handle_event("comparison_helper_open", _params, socket) do
    case socket.assigns.comparison_context do
      nil ->
        {:noreply, socket}

      context ->
        {:noreply, socket |> AgentPanel.set_context(context) |> AgentPanel.open()}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("load_more_comparison_choices", _params, socket) do
    {:noreply, load_comparison_choices(socket, socket.assigns.comparison_cursor)}
  end

  # A change to either side or to the dates is a replacement: the running
  # comparison no longer describes what the form says, so it is cancelled and
  # its request reference retired. The draft is kept exactly as entered.
  @impl Phoenix.LiveView
  def handle_event("select_comparison", %{"comparison" => draft}, socket) when is_map(draft) do
    {:noreply,
     socket
     |> cancel_comparison()
     |> assign(:comparison_form, comparison_form(draft))
     |> retain_chosen_comparison(draft)
     |> assign(:comparison_status, :idle)
     |> assign(:comparison_notice, nil)
     |> assign(:comparison_result, nil)
     |> reset_comparison_view()}
  end

  def handle_event("select_comparison", _params, socket), do: {:noreply, socket}

  # The Compare button is gone while a comparison is held, so only a replayed or
  # forged event gets here. Starting over it would overwrite the held coordinator
  # and request reference, orphaning that coordinator and the claims it owns.
  @impl Phoenix.LiveView
  def handle_event("start_comparison", _params, %{assigns: %{comparison_status: status}} = socket)
      when status in [:running, :cancelling],
      do: {:noreply, socket}

  # Authorization is checked again here, on the server, immediately before any
  # claim is taken. The selected runs and window are re-resolved from the form
  # draft rather than from anything the client kept.
  def handle_event("start_comparison", %{"comparison" => draft}, socket) when is_map(draft) do
    socket = assign(socket, :comparison_notice, nil)
    scope = comparison_scope(socket)

    case ReleaseComparison.resolve_selection(scope, selection_params(draft)) do
      {:ok, selection} ->
        {:noreply, start_coordinator(socket, selection, draft)}

      {:error, reason} when is_atom(reason) ->
        {:noreply, refuse_comparison(socket, draft, reason)}

      # A selection this page cannot make sense of is refused like any other,
      # never rendered and never allowed to reach a claim.
      _unexpected ->
        {:noreply, refuse_comparison(socket, draft, :unavailable)}
    end
  end

  def handle_event("start_comparison", _params, socket), do: {:noreply, socket}

  # Inspecting a row reveals that row's own detail. It never changes the scope
  # and never re-reads anything: the row is already in the held result.
  @impl Phoenix.LiveView
  def handle_event(
        "inspect_comparison_row",
        %{"collection" => collection, "row" => row} = params,
        socket
      ) do
    stream = comparison_stream(collection)

    if not is_nil(stream) and is_binary(row) do
      detail =
        socket.assigns.comparison_view
        |> inspected_row(stream, row)
        |> case do
          nil -> nil
          entry -> Map.put(entry, :limit, page_limit(params["limit"]))
        end

      {:noreply,
       socket
       |> assign(:comparison_inspected, detail)
       |> assign(:comparison_inspected_route, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("inspect_comparison_row", _params, socket), do: {:noreply, socket}

  # Inspecting a grouped route row resolves the row against the rows this render
  # would draw: the row must be in the held result *and* pass the kind filter in
  # force, so a forged id cannot open a row the editor cannot see.
  @impl Phoenix.LiveView
  def handle_event("inspect_comparison_route", %{"row" => row}, socket) when is_binary(row) do
    detail =
      case socket.assigns.comparison_view do
        nil ->
          nil

        view ->
          view
          |> ComparePresentation.route_rows(socket.assigns.comparison_kind_filter)
          |> Enum.find(&(&1.id == row))
      end

    {:noreply,
     socket
     |> assign(:comparison_inspected_route, detail)
     |> assign(:comparison_inspected, nil)}
  end

  def handle_event("inspect_comparison_route", _params, socket), do: {:noreply, socket}

  # One bounded page of one collection. The page only ever re-reads the
  # immutable result already held in assigns: the native result itself is never
  # replaced, so paging cannot make a row disappear from the comparison.
  @impl Phoenix.LiveView
  def handle_event(
        "page_comparison",
        %{"collection" => collection, "offset" => offset} = params,
        socket
      ) do
    with stream when not is_nil(stream) <- comparison_stream(collection),
         offset when is_binary(offset) <- offset,
         {page, ""} <- Integer.parse(offset) do
      if page >= 0 do
        {:noreply,
         stream_comparison_collection(socket, stream, page, page_limit(params["limit"]))}
      else
        {:noreply, socket}
      end
    else
      _refused -> {:noreply, socket}
    end
  end

  def handle_event("page_comparison", _params, socket), do: {:noreply, socket}

  # Narrowing is explicit and additive only: the form names route pairs and
  # dates this comparison already proved, and the server revalidates both
  # against the held result. An empty or unknown selection is refused with the
  # draft retained, and never narrows anything.
  @impl Phoenix.LiveView
  def handle_event("narrow_comparison", %{"comparison_scope" => draft}, socket)
      when is_map(draft) do
    socket = assign(socket, :comparison_scope_form, comparison_scope_form(draft))

    case socket.assigns.comparison_view do
      nil ->
        {:noreply, socket}

      view ->
        case scope_selection(draft, view) do
          {:ok, selection} ->
            {:noreply, apply_comparison_scope(socket, selection)}

          :empty ->
            {:noreply,
             socket
             |> assign(:comparison_scope_notice, @comparison_scope_notice)
             |> assign(:comparison_scope, nil)
             |> stream_comparison(view)}

          :invalid ->
            {:noreply,
             socket
             |> assign(:comparison_scope_notice, @comparison_scope_invalid_notice)
             |> assign(:comparison_scope, nil)
             |> stream_comparison(view)}
        end
    end
  end

  def handle_event("close_comparison_detail", _params, socket),
    do:
      {:noreply,
       socket
       |> assign(:comparison_inspected, nil)
       |> assign(:comparison_inspected_route, nil)}

  def handle_event("narrow_comparison", _params, socket), do: {:noreply, socket}

  # Clearing the scope shows the whole comparison again. The full native result
  # was never replaced, so this restores it without recomputing anything - and
  # re-attaches the complete copy, because the admitted context must describe
  # what is on screen and the screen is the whole comparison again.
  @impl Phoenix.LiveView
  def handle_event("clear_comparison_scope", _params, socket) do
    case socket.assigns.comparison_result do
      nil ->
        {:noreply, socket}

      result ->
        {:noreply,
         socket
         |> assign_comparison_view(result.comparison)
         |> assign(:comparison_scope, nil)
         |> assign(:comparison_scope_notice, nil)
         |> assign(:comparison_scope_form, comparison_scope_form(%{}))
         |> assign(:comparison_inspected_route, nil)
         |> stream_comparison(result.comparison)
         |> attach_comparison_context(result, :all)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("cancel_comparison", _params, socket) do
    # The request reference is deliberately kept: the coordinator answers the
    # cancellation itself, and that answer is what ends the "Cancelling…" band.
    {:noreply,
     socket
     |> request_cancellation()
     |> assign(:comparison_status, :cancelling)
     |> assign(:comparison_notice, nil)}
  end

  # Closing the comparison region retires the request reference and clears the
  # admitted result, so a reopened comparison can never adopt the previous
  # request's answer.
  @impl Phoenix.LiveView
  def handle_event("close_comparison", _params, socket) do
    {:noreply,
     socket
     |> cancel_comparison()
     |> reset_comparison()}
  end

  # A kind chip narrows the rendered route table only; it never changes the
  # held result. An unknown value leaves the filter untouched rather than
  # naming a kind this page does not render.
  @impl Phoenix.LiveView
  def handle_event("filter_comparison_kind", %{"kind" => value}, socket) do
    case comparison_kind_filter(value) do
      {:ok, filter} ->
        {:noreply,
         socket
         |> assign(:comparison_kind_filter, filter)
         |> assign(:comparison_inspected_route, nil)}

      :ignore ->
        {:noreply, socket}
    end
  end

  def handle_event("filter_comparison_kind", _params, socket), do: {:noreply, socket}

  defp start_coordinator(socket, selection, draft) do
    request_ref = System.unique_integer([:positive])

    case ReleaseComparison.start(
           comparison_scope(socket),
           selection_params(draft),
           self(),
           request_ref
         ) do
      {:ok, pid} ->
        socket
        |> assign(:comparison_form, comparison_form(draft))
        |> retain_chosen_comparison(draft, selection)
        |> assign(:comparison_status, :running)
        |> assign(:comparison_notice, nil)
        |> assign(:comparison_result, nil)
        |> reset_comparison_view()
        |> assign(:comparison_request_ref, request_ref)
        |> assign(:comparison_coordinator, pid)
        |> assign(:comparison_monitor, monitor_coordinator(pid))

      {:error, :unavailable} ->
        refuse_comparison(socket, draft, :unavailable)
    end
  end

  # The refusal keeps the entered draft and the form the page already had: a
  # refused comparison never clears the export form or the check panel.
  defp refuse_comparison(socket, draft, reason) do
    socket
    |> assign(:comparison_form, comparison_form(draft))
    |> assign(:comparison_status, :refused)
    |> assign(
      :comparison_notice,
      Map.get(@comparison_reason_notices, reason, @comparison_start_failed_notice)
    )
  end

  defp finish_comparison(socket, outcome) do
    socket = demonitor(socket, :comparison_monitor)
    finish_comparison_status(socket, outcome)
  end

  defp finish_comparison_status(socket, {:ok, result}) do
    # A membership withdrawn while the comparison ran is the same opaque answer
    # as one withdrawn before it started, and it never reaches the assigns.
    socket =
      if Scope.authorized_context(comparison_scope(socket)) == :ok do
        socket
        |> assign(:comparison_status, :completed)
        |> assign(:comparison_fingerprint, result.fingerprint)
        |> assign(:comparison_result, result)
        # The finished band names the two files from the result the coordinator
        # actually compared, so the sentence cannot describe a different pair
        # than the one that was read.
        |> assign(:comparison_chosen, compared_rows(socket, result))
        |> assign(:comparison_notice, nil)
        |> assign_comparison_view(result.comparison)
        |> assign(:comparison_true_totals, Map.new(@comparison_collections, &{&1, 0}))
        |> stream_comparison(result.comparison)
        # Only the complete comparison attaches on its own. A narrowed scope is
        # the editor's explicit choice, so it attaches when they make it.
        |> attach_comparison_context(result, :all)
      else
        socket
        |> assign(:comparison_status, :refused)
        |> assign(:comparison_notice, Map.fetch!(@comparison_reason_notices, :unavailable))
      end

    socket
    |> assign(:comparison_coordinator, nil)
    |> assign(:comparison_monitor, nil)
    |> assign(:comparison_request_ref, nil)
  end

  defp finish_comparison_status(socket, {:error, reason}) do
    socket
    |> assign(:comparison_status, :refused)
    |> assign(
      :comparison_notice,
      Map.get(@comparison_reason_notices, reason, @comparison_start_failed_notice)
    )
    |> assign(:comparison_coordinator, nil)
    |> assign(:comparison_monitor, nil)
    |> assign(:comparison_request_ref, nil)
  end

  # Cancellation is scoped to this page's own coordinator and request reference.
  # It never touches the export run, the check panel or any draft.
  defp request_cancellation(%{assigns: %{comparison_coordinator: nil}} = socket), do: socket

  defp request_cancellation(%{assigns: %{comparison_coordinator: pid}} = socket) do
    ReleaseComparison.cancel(pid, socket.assigns.comparison_request_ref)
    demonitor(socket, :comparison_monitor)
  end

  # Retiring the request reference is what makes the previous comparison's
  # answer stale: a replacement, a close or a version change drops it here, so
  # the retired coordinator's terminal message can no longer match.
  defp cancel_comparison(socket) do
    socket
    |> request_cancellation()
    |> assign(:comparison_coordinator, nil)
    |> assign(:comparison_monitor, nil)
    |> assign(:comparison_request_ref, nil)
    |> assign(:comparison_fingerprint, nil)
  end

  # The chosen rows are server-held. A submitted run id is only accepted when it
  # is one this page listed, so a forged value names nothing in the status band.
  defp retain_chosen_comparison(socket, draft) do
    assign(socket, :comparison_chosen, chosen_rows(known_choices(socket), draft))
  end

  defp retain_chosen_comparison(socket, draft, selection) do
    rows =
      known_choices(socket)
      |> Map.put(to_string(selection.left.run_id), artifact_row(selection.left))
      |> Map.put(to_string(selection.right.run_id), artifact_row(selection.right))

    assign(socket, :comparison_chosen, chosen_rows(rows, draft))
  end

  defp known_choices(socket),
    do: Map.new(socket.assigns.comparison_choices.rows, &{to_string(&1.run_id), &1})

  # The identities the result carries, kept beside the rows this page listed so
  # a file whose row has left the current page still names itself truthfully.
  defp compared_rows(socket, result) do
    known = known_choices(socket)

    %{
      left: Map.get(known, to_string(result.left.run_id)) || artifact_row(result.left),
      right: Map.get(known, to_string(result.right.run_id)) || artifact_row(result.right)
    }
  end

  defp chosen_rows(rows, draft) do
    %{
      left: Map.get(rows, to_string(Map.get(draft, "left_run_id"))),
      right: Map.get(rows, to_string(Map.get(draft, "right_run_id")))
    }
  end

  # The name a completed comparison reports when the page has no listed row for
  # it: the export type the artifact identity itself recorded, never a guess at
  # a version name.
  defp artifact_row(identity) do
    %{
      run_id: identity.run_id,
      version_name: nil,
      created_at: nil,
      export_type: identity.export_type
    }
  end

  # Only the four fields the form owns travel to the domain. The source version
  # identity is never submitted: `resolve_selection/2` resolves each run's own
  # version inside the organization's scope.
  defp selection_params(draft) do
    %{
      "left_run_id" => Map.get(draft, "left_run_id"),
      "right_run_id" => Map.get(draft, "right_run_id"),
      "from" => Map.get(draft, "from"),
      "to" => Map.get(draft, "to")
    }
  end

  # -- assistant context -------------------------------------------------------

  # Freezing is the shared AI04 seam's decision, not this page's: the page hands
  # over the finished native result and reads back either an admitted context or
  # the reason there is none.
  #
  # A refusal changes only what the helper may read. The native result, the
  # streams and the drafted scope all stay exactly as they were, because the
  # comparison was proved here and the byte ceiling limits the copy, not the
  # finding.
  defp attach_comparison_context(socket, result, selection) do
    case AssistantContext.freeze(comparison_scope(socket).resource_context, result, selection) do
      {:ok, context} ->
        socket
        |> assign(:comparison_context, context)
        |> assign(:comparison_context_notice, nil)
        |> bind_comparison_helper()

      {:error, reason} ->
        socket
        |> assign(:comparison_context, nil)
        |> assign(:comparison_context_notice, reason)
        |> bind_comparison_helper()
    end
  end

  # Replacing the comparison - a new selection, a close, a version change -
  # releases the admitted copy together with the result it described, so a
  # conversation can never answer from rows the page is no longer showing.
  defp reset_comparison_context(socket) do
    socket
    |> assign(:comparison_context, nil)
    |> assign(:comparison_context_notice, nil)
    |> bind_comparison_helper()
  end

  # Only the panel's own binding moves. While the panel holds the one helper
  # this page mounts, a replaced copy is bound the way `set_context/2` replaces
  # any context (this panel detaches from its session and clears its
  # transcript; the session, other tabs and the native comparison carry on), and
  # no copy at all closes the panel and clears its context, because the
  # comparison it was about is gone. There is no other helper to fall back to.
  defp bind_comparison_helper(%{assigns: %{agent_pack_id: "release_comparison"}} = socket) do
    case socket.assigns.comparison_context do
      nil ->
        socket
        |> assign(:agent_open?, false)
        |> AgentPanel.set_context(nil)

      context ->
        AgentPanel.set_context(socket, context)
    end
  end

  defp bind_comparison_helper(socket), do: socket

  defp comparison_scope(socket) do
    %Scope{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      user_id: socket.assigns.current_user.id,
      user_email: socket.assigns.current_user.email,
      pack_id: "release_comparison",
      version_name: socket.assigns.current_gtfs_version.name,
      resource_context: Scope.context({:version, socket.assigns.current_gtfs_version.id})
    }
  end

  defp load_comparison_choices(socket, cursor \\ nil) do
    case ReleaseComparison.list_choices(comparison_scope(socket),
           limit: @comparison_page_size,
           cursor: cursor
         ) do
      {:ok, %{rows: rows, next_cursor: next_cursor}} ->
        # Pages accumulate, so a run chosen on an earlier page stays selectable
        # instead of disappearing from the form.
        known = socket.assigns.comparison_choices.rows
        merged = Enum.uniq_by(known ++ rows, & &1.run_id)

        socket
        |> assign(:comparison_choices, %{rows: merged, next_cursor: next_cursor})
        |> assign(:comparison_cursor, next_cursor)

      {:error, :unavailable} ->
        assign(socket, :comparison_choices, %{rows: [], next_cursor: nil})
    end
  end

  # Navigating to another version is a different feed, so the comparison ends
  # here rather than answering under the new version's identity.
  defp reset_comparison_on_version_change(socket) do
    if socket.assigns[:comparison_version_id] == socket.assigns.current_gtfs_version.id do
      socket
    else
      socket
      |> cancel_comparison()
      |> reset_comparison()
      |> assign(:comparison_version_id, socket.assigns.current_gtfs_version.id)
    end
  end

  # The initial selection is a starting point, not a decision: the newest
  # comparable file is the candidate and the second-newest is the earlier one,
  # so the editor corrects a default instead of choosing both files. A
  # `?newer=<run id>` from the evidence card replaces the candidate; a
  # malformed, pathways, expired or foreign id is ignored without error. The
  # dates stay blank.
  defp initialize_comparison_defaults(socket, params) do
    rows = socket.assigns.comparison_choices.rows

    case prefilled_comparison_row(socket, params["newer"]) do
      nil ->
        apply_comparison_defaults(socket, rows, List.first(rows))

      row ->
        rows = Enum.uniq_by([row | rows], & &1.run_id)

        socket
        |> assign(:comparison_choices, %{socket.assigns.comparison_choices | rows: rows})
        |> apply_comparison_defaults(rows, row)
    end
  end

  defp apply_comparison_defaults(socket, rows, right) do
    left = Enum.find(rows, &(&1.run_id != (right && right.run_id)))

    chosen = %{left: left, right: right}

    form =
      comparison_form(%{
        "left_run_id" => run_id_string(left),
        "right_run_id" => run_id_string(right)
      })

    socket
    |> assign(:comparison_form, form)
    |> assign(:comparison_chosen, chosen)
  end

  defp run_id_string(nil), do: ""
  defp run_id_string(row), do: to_string(row.run_id)

  # A `newer` id is only trusted after it resolves as this organization's own
  # full, retained run through the same scoped read the comparison uses. A
  # malformed UUID is refused before it can reach the query, and every refusal
  # is ignored rather than shown.
  defp prefilled_comparison_row(_socket, id) when not is_binary(id), do: nil

  defp prefilled_comparison_row(socket, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case ExportRuns.get_comparable(socket.assigns.current_organization.id, nil, uuid) do
          {:ok, run} -> ReleaseComparison.choice_row(run)
          {:error, _reason} -> nil
        end

      :error ->
        nil
    end
  end

  # -- comparison result -----------------------------------------------------

  def comparison_page_defaults,
    do: Map.new(@comparison_collections, &{&1, %{offset: 0, limit: @comparison_row_limit}})

  # The page's own collection names are accepted, and nothing else: a name this
  # result does not have is refused rather than read as some other collection.
  defp comparison_stream(collection) when is_binary(collection) do
    Enum.find(@comparison_collections, fn name -> to_string(name) == collection end)
  end

  defp comparison_stream(_collection), do: nil

  # A page limit is a display choice, so it is clamped rather than refused, and
  # never exceeds the documented maximum.
  defp page_limit(nil), do: @comparison_row_limit

  defp page_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, _rest} -> limit |> max(1) |> min(@comparison_row_limit_max)
      :error -> @comparison_row_limit
    end
  end

  defp page_limit(_value), do: @comparison_row_limit

  # Every collection is re-streamed from the result currently in view. A
  # completion, a narrowing and a cleared scope all land here, so there is one
  # place that decides what the page shows and the counters beside it.
  defp stream_comparison(socket, view) do
    Enum.reduce(@comparison_collections, socket, fn collection, acc ->
      stream_comparison_collection(acc, collection, 0, @comparison_row_limit, view)
    end)
  end

  defp stream_comparison_collection(socket, collection, offset, limit, view \\ nil) do
    view = view || socket.assigns.comparison_view
    {rows, true_total} = page(collection, view, offset, limit)

    socket
    |> assign(
      :comparison_page,
      Map.put(socket.assigns.comparison_page, collection, %{offset: offset, limit: limit})
    )
    |> assign(
      :comparison_true_totals,
      Map.put(socket.assigns.comparison_true_totals, collection, true_total)
    )
    |> stream(collection, rows, reset: true)
  end

  # A page is a slice of the immutable result's own already-stable list. The
  # true total is the whole collection's length, computed from the same result,
  # so a counter never drifts from the rows it counts.
  defp page(_collection, nil, _offset, _limit), do: {[], 0}

  defp page(collection, view, offset, limit) do
    rows = comparison_rows(collection, view)

    {Enum.slice(rows, offset, limit), length(rows)}
  end

  defp comparison_rows(:comparison_structural, view),
    do: Map.get(view, :structural_changes, [])

  defp comparison_rows(:comparison_unresolved, view), do: Map.get(view, :unresolved, [])
  defp comparison_rows(:comparison_unknowns, view), do: Map.get(view, :unknowns, [])

  # The row identity a stream uses is derived from the row's own deterministic
  # content, so the same result always produces the same DOM ids and a re-render
  # cannot repaint a row as a different one. A comparison row's own `:id` - a
  # route or trip identifier that repeats across dates - is deliberately not the
  # DOM id, because two rows on different dates would collide.
  defp configure_comparison_streams(socket) do
    Enum.reduce(@comparison_collections, socket, fn collection, acc ->
      stream_configure(acc, collection, dom_id: &comparison_row_id(collection, &1))
    end)
  end

  defp comparison_row_id(collection, row) do
    "#{collection}-#{row_fingerprint(row)}"
  end

  defp row_fingerprint(row) do
    row
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp inspected_row(nil, _collection, _row), do: nil

  defp inspected_row(view, collection, row_id) do
    case Enum.find(
           comparison_rows(collection, view),
           &(comparison_row_id(collection, &1) == row_id)
         ) do
      nil -> nil
      row -> Map.put(row, :dom_id, row_id)
    end
  end

  # The scope form speaks in route-pair keys and ISO dates. Both are validated
  # against the result in view, so a forged or stale key narrows nothing.
  defp scope_selection(draft, view) do
    keys = draft |> Map.get("route_pair_keys", []) |> List.wrap() |> Enum.map(&to_string/1)
    dates = draft |> Map.get("dates", []) |> List.wrap()

    available = view |> Compare.route_pairs() |> Enum.map(fn pair -> pair.key end)

    with [_ | _] <- keys,
         [_ | _] <- dates,
         {:ok, parsed} <- parse_scope_dates(dates),
         true <- Enum.all?(keys, &(&1 in available)) do
      {:ok, %{route_pair_keys: keys, dates: parsed}}
    else
      [] -> :empty
      _ -> :invalid
    end
  end

  defp parse_scope_dates(dates) do
    Enum.reduce_while(dates, {:ok, []}, fn date, {:ok, acc} ->
      case Date.from_iso8601(date) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, _reason} -> {:halt, :error}
      end
    end)
  end

  defp apply_comparison_scope(socket, selection) do
    result = socket.assigns.comparison_result

    case Compare.narrow(result.comparison, selection) do
      {:ok, view} ->
        socket
        |> assign_comparison_view(view)
        |> assign(:comparison_scope, selection)
        |> assign(:comparison_scope_notice, nil)
        |> assign(:comparison_inspected, nil)
        |> assign(:comparison_inspected_route, nil)
        |> stream_comparison(view)
        |> attach_comparison_context(result, selection)

      # A refused scope shows the whole comparison again, so the summary, the
      # rows and the helper's copy keep describing the same result.
      {:error, :invalid_scope} ->
        socket
        |> assign_comparison_view(result.comparison)
        |> assign(:comparison_scope_notice, @comparison_scope_invalid_notice)
        |> assign(:comparison_scope, nil)
        |> assign(:comparison_inspected, nil)
        |> assign(:comparison_inspected_route, nil)
        |> stream_comparison(result.comparison)
        |> attach_comparison_context(result, :all)
    end
  end

  defp comparison_scope_form(draft) do
    to_form(
      %{
        "route_pair_keys" => draft |> Map.get("route_pair_keys", []) |> List.wrap(),
        "dates" => draft |> Map.get("dates", []) |> List.wrap()
      },
      as: :comparison_scope
    )
  end

  defp reset_comparison(socket) do
    socket
    |> assign(:comparison_form, comparison_form(%{}))
    |> assign(:comparison_chosen, %{left: nil, right: nil})
    |> assign(:comparison_status, :idle)
    |> assign(:comparison_notice, nil)
    |> assign(:comparison_request_ref, nil)
    |> assign(:comparison_fingerprint, nil)
    |> assign(:comparison_result, nil)
    |> reset_comparison_view()
  end

  # A comparison that no longer exists shows no result: the full native result,
  # the narrowed view, every stream and the page positions all go together, so
  # a reopened comparison cannot inherit a previous one.
  # The derived R6 presentation values travel with the view they describe, so a
  # narrowing, a completion and a cleared scope all publish them together and a
  # kind filter is dropped whenever a new view attaches or the comparison closes.
  defp assign_comparison_view(socket, nil) do
    socket
    |> assign(:comparison_view, nil)
    |> assign(:comparison_per_date, nil)
    |> assign(:comparison_day_classes, nil)
    |> assign(:comparison_conclusion, nil)
    |> assign(:comparison_kind_counts, nil)
    |> assign(:comparison_kind_filter, nil)
  end

  defp assign_comparison_view(socket, view) do
    per_date = ComparePresentation.per_date(view)

    socket
    |> assign(:comparison_view, view)
    |> assign(:comparison_per_date, per_date)
    |> assign(:comparison_day_classes, ComparePresentation.day_classes(per_date))
    |> assign(:comparison_conclusion, ComparePresentation.conclusion(view))
    |> assign(:comparison_kind_counts, ComparePresentation.kind_counts(view))
    |> assign(:comparison_kind_filter, nil)
  end

  # Only a genuinely complete, empty comparison retires the result card for the
  # no-change state. The held full result decides, not the narrowed view, so a
  # scope that happens to select no change cannot hide a full comparison's rows.
  defp no_change_result?(%{comparison: comparison}),
    do: ComparePresentation.no_change?(comparison)

  defp comparison_kind_filter(""), do: {:ok, nil}
  defp comparison_kind_filter("all"), do: {:ok, nil}

  defp comparison_kind_filter(value) when is_binary(value) do
    case Enum.find(@comparison_change_kinds, &(Atom.to_string(&1) == value)) do
      nil -> :ignore
      kind -> {:ok, kind}
    end
  end

  defp comparison_kind_filter(_value), do: :ignore

  defp reset_comparison_view(socket) do
    socket
    |> assign_comparison_view(nil)
    |> assign(:comparison_scope, nil)
    |> assign(:comparison_scope_form, comparison_scope_form(%{}))
    |> assign(:comparison_scope_notice, nil)
    |> assign(:comparison_inspected, nil)
    |> assign(:comparison_inspected_route, nil)
    |> assign(:comparison_page, comparison_page_defaults())
    |> assign(:comparison_true_totals, Map.new(@comparison_collections, &{&1, 0}))
    |> reset_comparison_context()
    |> stream(:comparison_structural, [], reset: true)
    |> stream(:comparison_unresolved, [], reset: true)
    |> stream(:comparison_unknowns, [], reset: true)
  end

  defp comparison_form(draft) do
    to_form(
      %{
        "left_run_id" => Map.get(draft, "left_run_id", ""),
        "right_run_id" => Map.get(draft, "right_run_id", ""),
        "from" => Map.get(draft, "from", ""),
        "to" => Map.get(draft, "to", "")
      },
      as: :comparison
    )
  end

  # The helper panel halts every raw `:DOWN` it does not own, so this page's own
  # monitor carries its own tag and reaches `handle_info/2` as that tagged message.
  defp monitor_coordinator(pid),
    do: :erlang.monitor(:process, pid, tag: :comparison_coordinator_down)

  defp demonitor(socket, key) do
    case socket.assigns[key] do
      nil ->
        socket

      ref ->
        # `Process.demonitor/2` answers `true`, so the socket is rebound rather
        # than returning its result.
        Process.demonitor(ref, [:flush])
        socket
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:release_comparison, request_ref, outcome}, socket) do
    if request_ref == socket.assigns.comparison_request_ref do
      {:noreply, finish_comparison(socket, outcome)}
    else
      # A stale request reference can never win over the current one.
      {:noreply, socket}
    end
  end

  # The coordinator is monitored so an exit that delivers no terminal message is
  # still reported. It becomes a worker exit only while it is still the current
  # request; a replaced coordinator's exit changes nothing.
  @impl Phoenix.LiveView
  def handle_info({:comparison_coordinator_down, ref, :process, pid, _reason}, socket) do
    if socket.assigns.comparison_monitor == ref and
         socket.assigns.comparison_coordinator == pid do
      {:noreply,
       socket
       |> assign(:comparison_status, :refused)
       |> assign(:comparison_notice, Map.fetch!(@comparison_reason_notices, :worker_exit))
       |> assign(:comparison_coordinator, nil)
       |> assign(:comparison_monitor, nil)}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
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
      <:sub_header>
        <.gtfs_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:compare} />
      </:sub_header>

      <div id="compare-page" class="ds-page">
        <.header>
          Compare files
          <:subtitle>Compare two retained full feed exports over one explicit date range.</:subtitle>
          <:actions>
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
          </:actions>
        </.header>

        <div
          id="compare-helper-focus"
          phx-hook=".CompareHelperFocus"
          class={[
            "min-w-0 lg:grid lg:gap-6",
            @agent_open? && "lg:grid-cols-[minmax(0,1fr)_24rem]"
          ]}
        >
          <div class={["min-w-0", @agent_open? && "hidden lg:block"]}>
            <div class="mt-2 grid min-w-0 gap-6">
              <.comparison
                form={@comparison_form}
                choices={@comparison_choices}
                chosen={@comparison_chosen}
                status={@comparison_status}
                notice={@comparison_notice}
                result={@comparison_result}
                version_id={@current_gtfs_version.id}
              />

              <.comparison_results
                :if={@comparison_result}
                result={@comparison_result}
                view={@comparison_view}
                scope={@comparison_scope}
                scope_form={@comparison_scope_form}
                scope_notice={@comparison_scope_notice}
                inspected={@comparison_inspected}
                inspected_route={@comparison_inspected_route}
                no_change?={no_change_result?(@comparison_result)}
                page={@comparison_page}
                true_totals={@comparison_true_totals}
                kind_filter={@comparison_kind_filter}
                per_date={@comparison_per_date}
                day_classes={@comparison_day_classes}
                conclusion={@comparison_conclusion}
                kind_counts={@comparison_kind_counts}
              >
                <:structural_list>
                  <div
                    id="comparison-structural-rows"
                    phx-update="stream"
                    class="divide-y divide-subtle"
                  >
                    <.comparison_structural_row
                      :for={{dom_id, change} <- @streams.comparison_structural}
                      dom_id={dom_id}
                      change={change}
                    />
                  </div>
                </:structural_list>
                <:unresolved_list>
                  <div
                    id="comparison-unresolved-rows"
                    phx-update="stream"
                    class="divide-y divide-subtle"
                  >
                    <.comparison_unresolved_row
                      :for={{dom_id, entry} <- @streams.comparison_unresolved}
                      dom_id={dom_id}
                      entry={entry}
                    />
                  </div>
                </:unresolved_list>
                <:unknowns_list>
                  <div id="comparison-unknowns" phx-update="stream" class="divide-y divide-subtle">
                    <.comparison_unknown_row
                      :for={{dom_id, unknown} <- @streams.comparison_unknowns}
                      dom_id={dom_id}
                      unknown={unknown}
                    />
                  </div>
                </:unknowns_list>
              </.comparison_results>

              <.comparison_helper
                :if={@comparison_result}
                context={@comparison_context}
                notice={@comparison_context_notice}
                open?={@agent_open? and @agent_pack_id == "release_comparison"}
              />
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
              scope_line={helper_scope_line(@agent_pack_id, @current_gtfs_version, @comparison_scope)}
              composer_hint={helper_composer_hint(@agent_pack_id)}
              status={@agent_status}
              entries={@streams.agent_entries}
              form={@agent_form}
              notice={@agent_notice}
              entries_empty?={@agent_entries_empty?}
              review_label={&agent_review_label/1}
            />
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CompareHelperFocus">
        export default {
          mounted() {
            this.handleEvent("agent:focus", ({id}) => document.getElementById(id)?.focus())
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp helper_scope_line("release_comparison", version, nil),
    do: "Compare · #{version.name} · whole comparison"

  defp helper_scope_line("release_comparison", version, _narrowed),
    do: "Compare · #{version.name} · narrowed comparison"

  defp helper_scope_line(_pack, version, _scope), do: "Compare · " <> version.name

  defp helper_composer_hint("release_comparison"),
    do: "Answers come from the comparison on this page."

  defp helper_composer_hint(_pack), do: "Review changes before applying."

  defp agent_review_label(_prepared), do: "Review prepared change"
end
