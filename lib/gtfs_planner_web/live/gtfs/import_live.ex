defmodule GtfsPlannerWeb.Gtfs.ImportLive do
  @moduledoc """
  LiveView for importing GTFS data.
  Requires the pathways_studio_editor role (editor only, not viewer).

  One page, two workflows with opposite consequences: a complete feed becomes a
  new version and never touches the one being viewed, while station changes edit
  the version being viewed after each change is approved. The person chooses one
  (`:source`) and only that workflow is on screen. Both forms stay mounted, the
  inactive one hidden, so the browser keeps each one's chosen files while the
  other is showing.
  """
  use GtfsPlannerWeb, :live_view

  import Ecto.Query, only: [from: 2]

  import GtfsPlannerWeb.Gtfs.ImportComponents

  import GtfsPlannerWeb.AgentComponents, only: [agent_panel: 1]
  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]
  import GtfsPlannerWeb.ResultComponents, only: [tone_badge: 1]

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Gtfs.Import

  alias GtfsPlanner.Gtfs.Import.{
    Result,
    ChangeArtifactStorage,
    ChangeRun,
    ChangeRunner,
    ChangeRuns,
    ParseError,
    SourceStorage
  }

  alias GtfsPlanner.Gtfs.Import.ChangeRunReview
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.Import.Runner
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.StationAssistant
  alias GtfsPlanner.Gtfs.StationJournal
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.AgentPanel
  alias GtfsPlannerWeb.Gtfs.LeftOutWording
  alias GtfsPlannerWeb.ProductSurfaces

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_editor}

  # List of recognized GTFS filenames
  @recognized_gtfs_files MapSet.new(Import.supported_filenames())

  # Runs that stopped before publishing and can be discarded (whole-target
  # cleanup) rather than published. `pending` and `running` are still active,
  # `cleaning` is in progress, and `published`/`cleaned` are terminal and never
  # recoverable.
  @stopped_states ~w(failed partial interrupted publication_failed cleanup_failed)

  @name_required_message "Enter a name for the new version."
  @name_taken_message "A version with this name already exists"

  @permission_error "You no longer have permission to import GTFS data. " <>
                      "Ask an organization administrator to restore your access."

  # Upload limits for a feed import. A staged upload set may total every file at its
  # limit, so the per-run storage budget is their product; the artifact root's own
  # capacity limit still applies.
  @max_upload_entries 50
  @max_upload_file_bytes 200_000_000
  @max_import_run_bytes @max_upload_entries * @max_upload_file_bytes

  @import_busy_message "Another import is running. Try again when it finishes."
  @change_busy_message "Another change review is running. Try again when it finishes."

  @source_options [
    %{
      value: "feed",
      label: "A complete feed",
      description:
        "A schedule from your scheduling system or an earlier export. Creates a new version.",
      hint: "GTFS feed (.zip)"
    },
    %{
      value: "station",
      label: "Station changes",
      description:
        "Levels, stops and pathways to add or update. You review each change before it’s applied.",
      hint: "levels.txt · stops.txt · pathways.txt"
    }
  ]

  @diff_filters %{
    "all" => :all,
    "add" => :add,
    "modify" => :modify,
    "remove" => :remove,
    "conflict" => :conflict
  }

  @max_failed_decisions 50

  # The one measurement this slice accepts. Both values are the domain's own
  # (`ChangeRunReview`), repeated here only as the options the native form
  # offers; a forged unit or meaning is still refused by the normalizer rather
  # than by this page.
  @observation_field "min_width"
  @observation_meaning "minimum_clear_width"
  @observation_units [{"Metres (m)", "m"}, {"Centimetres (cm)", "cm"}, {"Millimetres (mm)", "mm"}]
  @observation_meanings [{"Minimum clear width", @observation_meaning}]
  @observation_date_limit 50

  # What a reviewer is told when the proposal they clicked no longer describes
  # this page's station, run and frozen source - or no longer exists at all. It
  # is one sentence and discloses nothing about another station or run.
  @prepared_missing_notice "That suggestion is no longer part of this review. Ask the helper to prepare it again."

  # What each refusal the domain reports means for the person who typed the row.
  # An unrecognized reason still renders, rather than being dropped.
  @observation_rejections %{
    "unsupported_unit" => "metres, centimetres and millimetres are the only units.",
    "missing_meaning" => "say that the measurement is the minimum clear width.",
    "unsupported_field" => "only a pathway's minimum width is captured here.",
    "invalid_value" => "enter the measured number as it was written down.",
    "nonpositive_value" => "a width must be greater than zero.",
    "invalid_captured_date" => "enter the capture date as a real date.",
    "invalid_source_ref" => "name the source this measurement came from.",
    "invalid_target" => "choose the pathway this measurement is for.",
    "conflicting_duplicate" => "another measurement of this pathway disagrees with it.",
    "foreign_journal_reference" =>
      "name a note of this station, or a source reference that is not a note."
  }

  @diff_actions %{
    "add" => :add,
    "modify" => :modify,
    "remove" => :remove,
    "conflict" => :conflict
  }

  def recognized_gtfs_filenames do
    @recognized_gtfs_files
  end

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []
    organization_id = socket.assigns.current_organization.id

    # Reconcile expired leases and adopt runless legacy failed versions into
    # durable, organization-scoped recoverable runs before showing the page, so
    # a reconnect always reconstructs current state from PostgreSQL.
    ImportRuns.adopt_legacy_failed_targets(organization_id)
    ImportRuns.reconcile_expired(organization_id)
    ChangeRuns.reconcile_expired(organization_id)

    recoverable_runs = ImportRuns.list_recoverable(organization_id)
    route_version_id = socket.assigns.current_gtfs_version.id
    change_run = ChangeRuns.latest_for_version(organization_id, route_version_id)

    for run <- recoverable_runs do
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ImportRuns.topic(run.id))
    end

    if change_run, do: Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ChangeRuns.topic(change_run))

    {:ok,
     socket
     |> assign(:page_title, "Import data")
     |> assign(:source, opening_source(change_run))
     |> assign(:user_roles, user_roles)
     |> allow_upload(:gtfs_files,
       accept: ~w(.txt .csv .zip),
       max_entries: @max_upload_entries,
       max_file_size: @max_upload_file_bytes
     )
     |> allow_upload(:diff_files,
       accept: ~w(.txt .csv .zip),
       max_entries: 3,
       max_file_size: 50_000_000
     )
     |> assign(
       :form,
       to_form(%{"version_name" => ""}, as: :gtfs_import_form)
     )
     |> assign(:diff_form, to_form(%{}, as: :diff_upload))
     |> assign(:import_result, nil)
     |> assign(:import_agency_health, nil)
     |> assign(:import_left_out, [])
     |> assign(:import_target, nil)
     |> assign(:published_version, nil)
     |> assign(:version_name_touched, false)
     |> assign(:import_progress, nil)
     |> assign(:importing, false)
     |> assign(:unrecognized_upload_files, [])
     |> assign(:recovery_empty, recoverable_runs == [])
     |> assign(:recovery_count, length(recoverable_runs))
     |> assign(:pending_discard_run_id, nil)
     |> assign(:pending_discard_name, nil)
     |> assign(:discarded_name, nil)
     |> assign(:recovery_error, nil)
     |> assign(:processing_discard, false)
     |> assign(:processing_publish, nil)
     |> assign(:recovery_announce, nil)
     |> assign(:change_run, change_run)
     |> assign(:diff_step, diff_step(change_run))
     |> assign(:diff_summary, run_summary(change_run))
     |> assign(:diff_filter, :all)
     |> assign(:diff_parse_failures, [])
     |> assign(:diff_blockers, [])
     |> assign(:diff_preview_count, 0)
     |> assign(:apply_results, [])
     |> assign(:decisions_by_id, %{})
     |> assign(:decision_dependents, %{})
     |> assign(:evolution_targets, %{})
     |> assign_observation_scope(change_run)
     |> assign_station_suggestion(nil)
     |> stream_configure(:station_observation_rows, dom_id: &observation_row_dom_id/1)
     |> stream(:station_observation_rows, [])
     |> stream(:diff_decisions, [])
     |> stream(:diff_preview_decisions, [])
     |> stream(:import_recovery_runs, recoverable_runs,
       dom_id: fn run -> "import-run-#{run.id}" end
     )
     |> AgentPanel.mount("station_imports")
     |> refresh_change_review()}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/import")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      # Push event to JS hook to update localStorage
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      # Navigate to new version
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/import")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate", params, socket) do
    form_data = params["gtfs_import_form"] || %{}
    version_name = form_data["version_name"] || ""

    # Only surface the required-name error once the field has been touched
    # (blur or a prior submit); a blank name is never hidden behind a disabled
    # button.
    errors =
      if String.trim(version_name) == "" && socket.assigns.version_name_touched do
        [version_name: @name_required_message]
      else
        []
      end

    form = to_form(form_data, as: :gtfs_import_form, errors: errors)

    # Check for unrecognized files in uploads (.zip archives are always recognized)
    unrecognized_files =
      socket.assigns.uploads.gtfs_files.entries
      |> Enum.map(& &1.client_name)
      |> Enum.reject(fn name ->
        lower = String.downcase(name)
        MapSet.member?(@recognized_gtfs_files, lower) or String.ends_with?(lower, ".zip")
      end)

    socket =
      socket
      |> assign(:form, form)
      |> assign(:unrecognized_upload_files, unrecognized_files)
      |> clear_discarded_notice()

    socket =
      if errors != [],
        do: push_event(socket, "focus_first_error", %{selector: "#gtfs-import-version-name"}),
        else: socket

    {:noreply, socket}
  end

  # Choosing what to import shows that workflow and hides the other. Each form's
  # chosen files are kept, so switching back does not lose them.
  @impl true
  def handle_event("select_source", %{"source" => source}, socket)
      when source in ["feed", "station"] do
    socket = assign(socket, :source, String.to_existing_atom(source))

    # A finished review has been read; choosing the station workflow again means
    # a new one. Any other review's rows are streamed only while the station
    # workflow is showing, so choosing it re-sends them.
    socket =
      if source == "station" and socket.assigns.diff_step == :done,
        do: reset_diff(socket),
        else: refresh_change_review(socket)

    {:noreply, socket}
  end

  def handle_event("select_source", _params, socket), do: {:noreply, socket}

  # Return from the finished import to an empty form, so a second feed does not
  # start under the first one's name or result.
  @impl true
  def handle_event("import_another", _params, %{assigns: %{importing: false}} = socket) do
    {:noreply,
     socket
     |> assign(:import_result, nil)
     |> assign(:import_agency_health, nil)
     |> assign(:import_left_out, [])
     |> assign(:import_target, nil)
     |> assign(:published_version, nil)
     |> assign(:version_name_touched, false)
     |> assign(:form, to_form(%{"version_name" => ""}, as: :gtfs_import_form))
     |> clear_discarded_notice()
     |> push_event("focus_gtfs_import_files", %{})}
  end

  def handle_event("import_another", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate_diff", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("version_name_blur", _params, socket) do
    {:noreply, assign(socket, :version_name_touched, true)}
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :gtfs_files, ref)}
  end

  @impl true
  def handle_event("cancel-diff-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :diff_files, ref)}
  end

  @impl true
  def handle_event("import", params, socket) do
    form_data = params["gtfs_import_form"] || %{}
    version_name = form_data["version_name"] || ""
    socket = socket |> assign(:source, :feed) |> clear_discarded_notice()

    cond do
      # Reject a crafted submission while an import is already active so a
      # replayed event cannot bypass the disabled-button state or start a
      # duplicate task for a target already being written.
      socket.assigns.importing ->
        {:noreply, socket}

      # Reject an empty-file submission (no upload entries) so a crafted event
      # cannot start an import with nothing to write.
      socket.assigns.uploads.gtfs_files.entries == [] ->
        {:noreply,
         socket
         |> assign(:version_name_touched, true)
         |> assign(:form, to_form(form_data, as: :gtfs_import_form))
         |> assign(:import_result, {:error, nil, :no_files_selected})}

      true ->
        create_and_start_import(socket, form_data, version_name)
    end
  end

  # --- recovery actions ------------------------------------------------------

  # Open the confirmation for one recoverable run. The dialog names the version
  # and what goes with it; nothing is deleted until it is confirmed.
  @impl true
  def handle_event("begin_discard", %{"run_id" => run_id}, socket) do
    with binary_id when not is_nil(binary_id) <- load_run_id(run_id),
         %Run{} = run <- find_recoverable_run(socket, binary_id),
         true <- discardable?(run) do
      {:noreply,
       socket
       |> assign(:pending_discard_run_id, run.id)
       |> assign(:pending_discard_name, run.version_name)
       |> assign(:recovery_error, nil)
       |> assign(:recovery_announce, "Confirm deleting #{run.version_name}")}
    else
      _ -> {:noreply, socket}
    end
  end

  # Close the confirmation without deleting anything.
  @impl true
  def handle_event("cancel_discard", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_discard_run_id, nil)
     |> assign(:pending_discard_name, nil)
     |> assign(:processing_discard, false)
     |> assign(:recovery_announce, nil)}
  end

  # Retry publication for a run in `publication_failed`. Re-reads organization-
  # scoped durable state; cross-org or wrong-state crafted events are rejected.
  @impl true
  def handle_event("publish_version", %{"run_id" => run_id}, socket) do
    organization_id = socket.assigns.current_organization.id

    case load_run_id(run_id) do
      nil ->
        {:noreply, socket}

      binary_id ->
        case ImportRuns.retry_publication(organization_id, binary_id, socket.assigns.current_user) do
          {:ok, _run, _version} ->
            # Publication retry closes synchronously; enqueue the same durable
            # reload path used by runner broadcasts so the card is removed and
            # the processing state is cleared.
            send(self(), {:import_run_changed, binary_id})

            {:noreply,
             socket
             |> assign(:recovery_announce, "Publishing version")
             |> assign(:processing_publish, binary_id)}

          {:error, :forbidden} ->
            {:noreply,
             socket
             |> assign(:processing_publish, nil)
             |> put_flash(:error, @permission_error)}

          {:error, _reason} ->
            {:noreply, assign(socket, :processing_publish, nil)}
        end
    end
  end

  # Execute the discard after confirmation through the supervised cleanup
  # runner. Completion is applied from the runner's durable-state broadcast so
  # cleanup survives this LiveView disconnecting.
  @impl true
  def handle_event("delete_version", %{"run_id" => run_id}, socket) do
    organization_id = socket.assigns.current_organization.id
    actor = %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}

    socket = assign(socket, :processing_discard, true)

    case load_run_id(run_id) do
      nil ->
        {:noreply, discard_refused(socket)}

      binary_id ->
        Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ImportRuns.topic(binary_id))

        case Runner.start_cleanup(organization_id, binary_id, actor) do
          {:ok, _runner_pid} ->
            {:noreply,
             socket
             |> restream_recovery_run(organization_id, binary_id)
             |> assign(:processing_discard, binary_id)
             |> assign(:pending_discard_run_id, nil)
             |> assign(:pending_discard_name, nil)
             |> assign(:recovery_announce, "Cleanup in progress")}

          {:error, :busy} ->
            {:noreply, discard_refused(socket, @import_busy_message, @import_busy_message)}

          {:error, _reason} ->
            {:noreply, discard_refused(socket)}
        end
    end
  end

  @impl true
  def handle_event("compute_diff", _params, socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :diff_files, fn %{path: path}, entry ->
        {:ok, %{filename: entry.client_name, content: File.read!(path)}}
      end)

    {:noreply, socket |> assign(:source, :station) |> start_change_review(uploaded_files)}
  end

  @impl true
  def handle_event("diff-filter", %{"filter" => filter}, socket) do
    case Map.fetch(@diff_filters, filter) do
      {:ok, filter_atom} ->
        {:noreply,
         socket
         |> assign(:diff_filter, filter_atom)
         |> refresh_change_review()}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("approve-decision", %{"id" => id}, socket) do
    {:noreply, update_change_decision(socket, id, :approved)}
  end

  @impl true
  def handle_event("reject-decision", %{"id" => id}, socket) do
    {:noreply, update_change_decision(socket, id, :rejected)}
  end

  @impl true
  def handle_event("approve-all", %{"action" => action}, socket) do
    case Map.fetch(@diff_actions, action) do
      {:ok, action_atom} ->
        _ =
          ChangeRuns.approve_all(
            socket.assigns.current_organization.id,
            socket.assigns.change_run.id,
            action_atom
          )

        {:noreply, refresh_change_review(socket)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("apply-decisions", _params, socket) do
    {:noreply, request_change_apply(socket)}
  end

  # -- Accepted station measurements ------------------------------------------

  @impl true
  def handle_event("station-observation-scope", %{"station_observation_scope" => params}, socket) do
    previous = socket.assigns[:observation_station]
    station = observation_station(socket, Map.get(params, "station_stop_id"))

    {:noreply,
     socket
     |> assign(:observation_error, observation_station_error(station))
     |> assign(:observation_notice, observation_switch_notice(previous, station))
     |> assign_observation_station(station)
     |> stream_observation_rows()
     |> bind_observation_helper()}
  end

  @impl true
  def handle_event("station-observation-save", %{"station_observation" => params}, socket) do
    {:noreply, save_station_observation(socket, params)}
  end

  # The panel renders a review button on a prepared entry from its first turn.
  # Reviewing is a read: the stored proposal is retrieved from the conversation
  # that produced it, checked against this page's own frozen snapshot, and shown
  # for a person to decide. Nothing is approved, applied or written here
  # (INV-2); only `station-suggestion-confirm` reaches the native writer.
  @impl true
  def handle_event("agent_review_prepared", %{"entry" => id}, socket) do
    {:noreply, open_station_suggestion(socket, id)}
  end

  def handle_event("agent_review_prepared", _params, socket), do: {:noreply, socket}

  # Closing the review writes nothing and hands focus back to the card it came
  # from, so a person who decided against it is exactly where they started.
  @impl true
  def handle_event("station-suggestion-cancel", _params, socket) do
    {:noreply,
     socket
     |> cancel_station_suggestion()
     |> focus_suggestion_return()}
  end

  # The one deliberate act this flow offers. The page's own frozen source and
  # the reviewed selection go to the native confirmation, which revalidates
  # membership, run, station, source, status and every decision value inside its
  # transaction. Only a success refreshes the review; a refusal keeps the review
  # and every draft exactly as they were.
  @impl true
  def handle_event("station-suggestion-confirm", _params, socket) do
    {:noreply, confirm_station_suggestion(socket)}
  end

  @impl true
  def handle_event("station-observation-save", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel-diff-run", _params, socket), do: {:noreply, cancel_change_run(socket)}

  @impl true
  def handle_event("retry-diff-run", _params, socket), do: {:noreply, retry_change_run(socket)}

  @impl true
  def handle_event("start-over-diff", _params, socket) do
    with %ChangeRun{} = run <- socket.assigns[:change_run],
         {:ok, _started_over} <-
           ChangeRuns.start_over(
             socket.assigns.current_organization.id,
             run.id,
             socket.assigns.current_user
           ) do
      handle_event("reset-diff", %{}, socket)
    else
      {:error, :forbidden} ->
        {:noreply, socket |> put_flash(:error, @permission_error) |> refresh_change_review()}

      _ ->
        {:noreply, refresh_change_review(socket)}
    end
  end

  @impl true
  def handle_event("reset-diff", _params, socket) do
    {:noreply,
     socket
     |> discard_change_run()
     |> reset_diff()
     |> push_event("focus_diff_files", %{})}
  end

  defp observation_station_error(%Stop{}), do: nil
  defp observation_station_error(nil), do: "Choose one of the stations this review changes."

  # Return the station workflow to choosing files. The durable run is left as it
  # is; only what this page shows of it is cleared.
  defp reset_diff(socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.diff_files.entries, socket, fn entry, acc ->
        cancel_upload(acc, :diff_files, entry.ref)
      end)

    socket
    |> assign(:change_run, nil)
    |> assign(:diff_step, :upload)
    |> assign(:diff_summary, empty_diff_summary())
    |> assign(:diff_filter, :all)
    |> assign(:diff_parse_failures, [])
    |> assign(:diff_blockers, [])
    |> assign(:diff_preview_count, 0)
    |> assign(:apply_results, [])
    |> assign(:decisions_by_id, %{})
    |> assign(:evolution_targets, %{})
    |> stream_observation_rows()
    |> bind_observation_helper()
    |> stream(:diff_decisions, [], reset: true)
    |> stream(:diff_preview_decisions, [], reset: true)
  end

  # Reset discards the durable review, not only its client copy. A run left
  # active in the scope is the run the next compute adopts, and its staged
  # files would then surface as decisions for files this reader never staged.
  defp discard_change_run(socket) do
    case socket.assigns[:change_run] do
      %ChangeRun{} = run ->
        Phoenix.PubSub.unsubscribe(GtfsPlanner.PubSub, ChangeRuns.topic(run))

        _ =
          ChangeRuns.request_cancel(
            socket.assigns.current_organization.id,
            run.id,
            socket.assigns.current_user
          )

        socket

      _ ->
        socket
    end
  end

  @impl true
  def handle_info({:import_progress, progress}, socket) do
    {:noreply, assign(socket, :import_progress, progress)}
  end

  def handle_info({:import_phase, _phase}, socket) do
    {:noreply, socket}
  end

  # A page that reset or started over no longer shows the run, so its later changes
  # must not bring the run back.
  @impl true
  def handle_info(
        {:change_run_changed, run_id},
        %{assigns: %{change_run: %ChangeRun{id: run_id}}} = socket
      ) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    socket =
      case ChangeRuns.get_for_version(organization_id, version_id, run_id) do
        %ChangeRun{} = run ->
          Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ChangeRuns.topic(run))
          socket |> assign(:change_run, run) |> refresh_change_review()

        nil ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:change_run_changed, _run_id}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:import_run_changed, run_id}, socket) do
    # A terminal or progress transition was broadcast by the supervised Runner
    # (or a peer LiveView) for this organization's run. Reload the durable run
    # and re-stream it; if it is no longer recoverable, drop it from the list
    # and, when the run we started just published its target, surface the
    # success result the old task-owned flow used to return directly.
    organization_id = socket.assigns.current_organization.id

    recoverable_runs = ImportRuns.list_recoverable(organization_id)
    run = Enum.find(recoverable_runs, &(&1.id == run_id))
    recovery_count = length(recoverable_runs)

    socket =
      reconcile_recovery_run(
        socket,
        organization_id,
        run_id,
        run,
        recovery_count,
        recoverable_runs == []
      )

    socket =
      if socket.assigns.processing_publish == run_id and
           (is_nil(run) or run.state != "publication_failed") do
        assign(socket, :processing_publish, nil)
      else
        socket
      end

    socket = settle_discard(socket, organization_id, run_id, run)

    {:noreply, socket}
  end

  defp settle_discard(
         %{assigns: %{processing_discard: run_id}} = socket,
         organization_id,
         run_id,
         run
       ) do
    changed_run =
      run ||
        from(r in Run,
          where: r.id == ^run_id and r.organization_id == ^organization_id
        )
        |> GtfsPlanner.Repo.one()

    case changed_run do
      %Run{state: "cleaned", version_name: removed_name} ->
        socket
        |> assign(:pending_discard_run_id, nil)
        |> assign(:processing_discard, false)
        |> assign(:recovery_announce, "Discarded #{removed_name}")
        |> assign(:discarded_name, removed_name)
        |> assign(:source, :feed)
        |> assign(
          :form,
          to_form(%{"version_name" => removed_name}, as: :gtfs_import_form)
        )
        |> reset_uploads()
        |> push_event("focus_gtfs_import_files", %{})

      %Run{state: "cleanup_failed"} ->
        socket
        |> assign(:pending_discard_run_id, nil)
        |> assign(:processing_discard, false)

      _ ->
        socket
    end
  end

  defp settle_discard(socket, _organization_id, _run_id, _run), do: socket

  # When the run we started reaches `published`, the route-version we bound as
  # `:import_target` is now published. Render the success result with the
  # durable counts from the run's audit row so the import page announces it.
  defp success_for_published_target(socket, run_id) do
    target = socket.assigns[:import_target]

    if target do
      organization_id = socket.assigns.current_organization.id

      run =
        from(r in Run,
          where: r.id == ^run_id and r.organization_id == ^organization_id
        )
        |> GtfsPlanner.Repo.one()

      case Versions.get_gtfs_version_for_lifecycle(
             organization_id,
             target.id
           ) do
        %GtfsVersion{publication_status: "published"} = published ->
          counts = run_counts_to_result(run)

          result = %Result{
            counts: counts,
            unrecognized_files: [],
            topic: nil,
            archive_warnings: [],
            extensions: :not_present
          }

          socket
          |> assign(:import_result, {:ok, published, result})
          |> assign(:import_agency_health, import_agency_findings(organization_id, published))
          |> assign(:import_left_out, import_left_out(organization_id, published))
          |> assign(:import_target, published)
          |> assign(:published_version, published)
          |> assign(:importing, false)
          |> assign(:import_progress, nil)

        _ ->
          socket
          |> assign(:importing, false)
          |> assign(:import_progress, nil)
      end
    else
      socket
    end
  end

  # One id per action, and one per route: this block reports every route at
  # once, so the grouping review's id carries the route it opens.
  defp left_out_action_id(:group, route_id, _code), do: "import-left-out-group-#{route_id}"

  defp left_out_action_id(:schedules, route_id, code),
    do: "import-left-out-#{route_id}-#{code}-trips"

  # The findings the success result shows for the version just published (R11).
  # They are `FeedSettings.agency_health/2`'s own map for that version, read once
  # after publication, so the copy describes the imported version and never the
  # version the page was opened on (AC-27). This read takes no lock and changes
  # no publication state (CR-6).
  defp import_agency_findings(organization_id, published) do
    FeedSettings.agency_health(organization_id, published.id)
  end

  # The trips this import could not group, grouped by route, for the version it
  # just published and not the version the page was opened on. Import writes
  # `trips_custom` with a `pattern_derivation_reason` on each of them, and that
  # reason is what this reports; the reader is the same `Gtfs.left_out_trips/3`
  # the route's Patterns tab reads, so both pages say the same thing.
  #
  # A feed whose every trip is grouped leaves the list empty and the block out of
  # the result entirely. Each entry carries the route row when the feed still has
  # it, so the block can draw the route's own badge and name.
  defp import_left_out(organization_id, published) do
    case Gtfs.left_out_trips(organization_id, published.id) do
      [] ->
        []

      rows ->
        routes =
          organization_id
          |> Gtfs.list_routes(published.id)
          |> Map.new(&{&1.route_id, &1})

        rows
        |> Enum.group_by(& &1.route_id)
        |> Enum.map(fn {route_id, rows} ->
          %{
            route_id: route_id,
            route: Map.get(routes, route_id),
            trip_count: Enum.sum(Enum.map(rows, & &1.trip_count)),
            rows:
              rows
              |> LeftOutWording.rows()
              |> Enum.map(fn row ->
                row
                |> Map.put(:id, "import-left-out-#{route_id}-#{row.code}")
                |> Map.update!(:action, fn
                  nil ->
                    nil

                  action ->
                    Map.put(action, :id, left_out_action_id(action.target, route_id, row.code))
                end)
              end)
          }
        end)
        |> Enum.sort_by(& &1.route_id)
    end
  end

  # One finding per agency-health state the import can reach: a version with no
  # agency, or a version whose agencies disagree on or do not name a valid zone.
  # A clean feed renders no findings element at all.
  defp findings?(%{agency_count: 0}), do: true
  defp findings?(%{zone: {:unresolved, _reason}}), do: true
  defp findings?(%{zone: {:ok, _zone}}), do: false

  defp unresolved_zone?({:unresolved, _reason}), do: true
  defp unresolved_zone?({:ok, _zone}), do: false

  # The Agencies page names the same DisplayClock states with these same words
  # (INV-4), so a finding and the page it links to read as one vocabulary.
  defp zone_finding_title({:unresolved, :conflicting}), do: "Agencies use different timezones"
  defp zone_finding_title({:unresolved, :invalid}), do: "The agency timezone isn’t recognized"
  defp zone_finding_title({:unresolved, :missing}), do: "The agency timezone is missing"

  defp unassigned_routes_sentence(1),
    do: "1 route needs an operating agency before export."

  defp unassigned_routes_sentence(count),
    do: "#{count} routes need an operating agency before export."

  defp run_counts_to_result(nil), do: %{}

  defp run_counts_to_result(%Run{committed_counts: counts}) when is_map(counts) do
    Enum.reduce([:levels, :stops, :pathways], %{}, fn key, acc ->
      case fetch_committed_count(counts, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp fetch_committed_count(counts, key) do
    with :error <- Map.fetch(counts, key) do
      Map.fetch(counts, Atom.to_string(key))
    end
  end

  defp restream_recovery_run(socket, organization_id, run_id) do
    recoverable_runs = ImportRuns.list_recoverable(organization_id)

    socket =
      case Enum.find(recoverable_runs, &(&1.id == run_id)) do
        %Run{} = run -> stream_insert(socket, :import_recovery_runs, run, at: -1)
        nil -> socket
      end

    socket
    |> assign(:recovery_count, length(recoverable_runs))
    |> assign(:recovery_empty, recoverable_runs == [])
  end

  defp reconcile_recovery_run(socket, _organization_id, _run_id, %Run{} = run, count, empty?) do
    socket
    |> stream_insert(:import_recovery_runs, run, at: -1)
    |> assign(:recovery_count, count)
    |> assign(:recovery_empty, empty?)
    |> assign(:recovery_announce, recovery_announce_text(run))
    |> fail_started_import(run)
  end

  defp reconcile_recovery_run(socket, organization_id, run_id, nil, count, empty?) do
    gone_run =
      from(r in Run,
        where: r.id == ^run_id and r.organization_id == ^organization_id
      )
      |> GtfsPlanner.Repo.one()

    socket = maybe_delete_recovery_run(socket, gone_run)
    socket = assign_recovery_count(socket, count, empty?)

    if started_import_run?(socket, gone_run),
      do: success_for_published_target(socket, run_id),
      else: socket
  end

  # The run this page started is the one whose version is bound as `:import_target`.
  # Broadcasts about any other run in the organization never settle this page's import.
  defp started_import_run?(socket, %Run{gtfs_version_id: version_id}) do
    match?(%GtfsVersion{id: ^version_id}, socket.assigns[:import_target])
  end

  defp started_import_run?(_socket, nil), do: false

  # The import this page started ended in a recoverable state without publishing.
  # Free the form and show the failure beside it: the recovery card that offers the
  # next step is further down the page. In-progress runs keep the "Importing…" state.
  defp fail_started_import(%{assigns: %{importing: true}} = socket, %Run{} = run) do
    if started_import_run?(socket, run) and discardable?(run) do
      socket
      |> assign(:importing, false)
      |> assign(:import_progress, nil)
      |> assign(:import_result, {:error, socket.assigns.import_target, failure_reason(run)})
    else
      socket
    end
  end

  defp fail_started_import(socket, _run), do: socket

  defp failure_reason(%Run{state: "publication_failed", reason_code: reason_code}),
    do: {:publication_failed, reason_code}

  defp failure_reason(%Run{}), do: :import_not_finished

  # The delete could not start, for example because someone else claimed it
  # first. Say so where the list is, not only to assistive technology.
  defp discard_refused(socket) do
    discard_refused(
      socket,
      "Could not claim the failed version for cleanup",
      "That version couldn’t be deleted. It may already be deleting, or its state changed. Check its status below and try again."
    )
  end

  defp discard_refused(socket, announce, error) do
    socket
    |> assign(:processing_discard, false)
    |> assign(:pending_discard_run_id, nil)
    |> assign(:pending_discard_name, nil)
    |> assign(:recovery_announce, announce)
    |> assign(:recovery_error, error)
  end

  defp clear_discarded_notice(socket), do: assign(socket, :discarded_name, nil)

  defp maybe_delete_recovery_run(socket, %Run{} = run) do
    stream_delete(socket, :import_recovery_runs, run)
  end

  defp maybe_delete_recovery_run(socket, nil), do: socket

  defp assign_recovery_count(socket, count, empty?) do
    socket
    |> assign(:recovery_count, count)
    |> assign(:recovery_empty, empty?)
  end

  defp start_change_review(socket, uploaded_files) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    actor = %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}
    run_id = Ecto.UUID.generate()

    with {:ok, manifest} <-
           ChangeArtifactStorage.stage(organization_id, version_id, run_id, uploaded_files),
         {:ok, %ChangeRun{} = run} <-
           ChangeRuns.create_pending_compute(organization_id, version_id, actor, manifest, run_id) do
      if run.id != run_id, do: ChangeArtifactStorage.remove(organization_id, version_id, run_id)
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ChangeRuns.topic(run))
      {socket, run} = start_change_runner(socket, :compute, run)

      socket
      |> assign(:change_run, run)
      |> assign(:diff_filter, :all)
      |> refresh_change_review()
    else
      {:error, :forbidden} ->
        # The files were staged before the run was refused; nothing owns them.
        _ = ChangeArtifactStorage.remove(organization_id, version_id, run_id)
        put_flash(socket, :error, @permission_error)

      {:error, reason} ->
        socket
        |> assign(:diff_blockers, [%{reason: reason}])
        |> assign(:diff_step, :upload)
    end
  end

  # Starts the runner for a pending change run. When the runner supervisor is at
  # its cap the run never started, so it is closed as failed and the user is told
  # to try again; Retry review runs it from the same files and decisions.
  defp start_change_runner(socket, operation, %ChangeRun{} = run) do
    start =
      if operation == :compute,
        do: &ChangeRunner.start_compute/2,
        else: &ChangeRunner.start_apply/2

    case start.(run.organization_id, run.id) do
      {:error, :busy} ->
        case ChangeRuns.fail_unstarted(run.organization_id, run.id, run.lease_generation) do
          {:ok, failed} -> {put_flash(socket, :error, @change_busy_message), failed}
          {:error, _reason} -> {socket, run}
        end

      _started ->
        {socket, run}
    end
  end

  defp refresh_change_review(socket) do
    case socket.assigns[:change_run] do
      %ChangeRun{} = run ->
        organization_id = socket.assigns.current_organization.id

        run =
          ChangeRuns.get_for_version(
            organization_id,
            socket.assigns.current_gtfs_version.id,
            run.id
          ) || run

        decisions = ChangeRuns.list_decisions(organization_id, run.id)
        applicable = Enum.reject(decisions, &(&1.status == :preview))
        previews = Enum.filter(decisions, &(&1.status == :preview))
        filtered = filter_decisions(applicable, socket.assigns.diff_filter)
        evolution_targets = pathway_in_use_targets(organization_id, run, applicable)

        socket
        |> assign(:change_run, run)
        |> assign(:diff_step, diff_step(run))
        |> assign(:diff_summary, run_summary(run))
        |> assign(:diff_blockers, run_blockers(run))
        |> assign(:diff_parse_failures, run_diagnostics(run))
        |> assign(:diff_preview_count, length(previews))
        |> assign(:decisions_by_id, Map.new(applicable, &{&1.decision_id, &1}))
        |> assign(:decision_dependents, decision_dependents(run, filtered))
        |> assign(:evolution_targets, evolution_targets)
        |> assign_observation_scope(run)
        |> stream_observation_rows()
        |> bind_observation_helper()
        |> stream(:diff_decisions, filtered, reset: true)
        |> stream(:diff_preview_decisions, previews, reset: true)

      _ ->
        socket
        |> assign_observation_scope(nil)
        |> bind_observation_helper()
    end
  end

  # Counts what still uses each stop or level a review removes. Apply refuses a removal
  # while anything uses it, so the row warns before the user approves. The rows only render
  # in the review step. One grouped query per referencing table covers every removal.
  defp decision_dependents(%ChangeRun{state: :review} = run, decisions) do
    decisions
    |> Enum.filter(&(&1.action == :remove and &1.status != :applied))
    |> Enum.group_by(& &1.entity_type, & &1.natural_key)
    |> Enum.reduce(%{}, fn {entity_type, natural_keys}, dependents ->
      counts =
        Gtfs.import_dependent_counts(
          entity_type,
          run.organization_id,
          run.gtfs_version_id,
          natural_keys
        )

      Map.merge(dependents, Map.new(counts, fn {key, kinds} -> {{entity_type, key}, kinds} end))
    end)
  end

  defp decision_dependents(_run, _decisions), do: %{}

  # -- Accepted station measurements ------------------------------------------

  # Everything this page shows about accepted measurements is derived from the
  # run it is already reviewing: the stations a person may choose are the stations
  # whose pathways this review changes, and the pathways a measurement may target
  # are the pathways this review changes for that station. A client value names
  # one of these offered rows or nothing at all.
  # Rebuilt whenever the run changes. Adopting a different review clears the
  # station, its messages and its captures because a draft and a refusal from the
  # previous run no longer describe anything; refreshing the same review after a
  # native action keeps the station this person chose, and only rebuilds the
  # offered rows and the helper binding. Choosing a station clears messages in
  # the scope handler instead, so its own notice survives.
  defp assign_observation_scope(socket, %ChangeRun{} = run) do
    socket = assign(socket, :observation_stations, observation_station_options(socket, run))

    case socket.assigns[:observation_scope_run_id] do
      run_id when run_id == run.id ->
        socket
        |> assign_observation_station(socket.assigns[:observation_station])
        |> reset_observation_captures_for_run(run)

      _other ->
        socket
        |> assign_observation_station(nil)
        |> assign(:observation_error, nil)
        |> assign(:observation_notice, nil)
        |> assign(:observation_helper_notice, nil)
        |> assign(:observation_scope_run_id, run.id)
        |> reset_observation_captures_for_run(run)
    end
  end

  defp assign_observation_scope(socket, _run), do: socket

  # Every option the station choice offers, followed by the one the caller
  # resolved. A station the page does not offer resolves to nil here, which is
  # what makes a forged `phx-value-*` indistinguishable from a cleared select.
  defp assign_observation_station(socket, station) do
    run = socket.assigns.change_run

    socket
    |> assign(:observation_station, station)
    |> assign(
      :observation_scope_form,
      to_form(%{"station_stop_id" => station && station.stop_id},
        as: :station_observation_scope
      )
    )
    |> assign(:observation_pathways, observation_pathway_options(socket, run, station))
    |> assign(:observation_journal_entries, observation_journal_options(socket, station))
  end

  # Only the station this run's pathway decisions belong to can be measured, and
  # only through the endpoint-ancestry rule the rest of this page already uses
  # (`Gtfs.pathway_station_ids/3`).
  defp observation_station_options(socket, %ChangeRun{} = run) do
    if ChangeRunReview.computed_review_run?(run) do
      review_station_ids(socket, run)
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.map(
        &Gtfs.get_stop_by_stop_id(socket.assigns.current_organization.id, run.gtfs_version_id, &1)
      )
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.stop_name)
    else
      []
    end
  end

  defp observation_station(_socket, nil), do: nil

  defp observation_station(socket, stop_id) when is_binary(stop_id) do
    Enum.find(socket.assigns[:observation_stations] || [], &(&1.stop_id == stop_id))
  end

  defp observation_station(_socket, _stop_id), do: nil

  # Which station owns each pathway this review changes, by the same scoped
  # endpoint-ancestry rule the closure links on this page already use.
  defp review_station_ids(socket, %ChangeRun{} = run) do
    pathway_ids =
      socket.assigns.decisions_by_id
      |> Map.values()
      |> Enum.filter(&(&1.entity_type == :pathway))
      |> Enum.map(& &1.natural_key)
      |> Enum.uniq()

    Gtfs.pathway_station_ids(
      socket.assigns.current_organization.id,
      run.gtfs_version_id,
      pathway_ids
    )
  end

  defp observation_pathway_options(socket, %ChangeRun{} = run, %Stop{} = station) do
    review_station_ids(socket, run)
    |> Enum.filter(fn {_pathway_id, stop_ids} -> station.stop_id in stop_ids end)
    |> Enum.map(fn {pathway_id, _stop_ids} -> pathway_option(socket, run, pathway_id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.pathway_id)
  end

  defp observation_pathway_options(_socket, _run, _station), do: []

  # The label names what this review proposes for that pathway, so a person can
  # match a measurement to the change it supports without opening the row.
  defp pathway_option(socket, _run, pathway_id) do
    decision =
      socket.assigns.decisions_by_id
      |> Map.values()
      |> Enum.find(&(&1.entity_type == :pathway and &1.natural_key == pathway_id))

    case decision do
      nil ->
        nil

      decision ->
        %{
          pathway_id: pathway_id,
          label:
            "#{pathway_id} · #{decision.action} · uploaded #{observation_width(decision.uploaded_values) || "no width"} m"
        }
    end
  end

  defp observation_width(values) when is_map(values), do: Map.get(values, "min_width")
  defp observation_width(_values), do: nil

  # Journal notes are listed by date and target only: their text and photos stay
  # where the station's own notes show them, and a measurement names one by id.
  defp observation_journal_options(socket, %Stop{} = station) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    with {:ok, scope} <-
           StationJournal.resolve_scope(
             organization_id,
             version_id,
             station.id,
             socket.assigns.current_user.id
           ),
         entries when is_list(entries) <-
           StationJournal.list_entries(scope, order: :desc, limit: @observation_date_limit) do
      Enum.map(entries, fn entry ->
        %{id: entry.id, label: "#{journal_label(entry.captured_at)} · #{entry.target_type}"}
      end)
    else
      _other -> []
    end
  end

  defp observation_journal_options(_socket, _station), do: []

  defp journal_label(nil), do: "No date"

  defp journal_label(%DateTime{} = captured_at),
    do: Date.to_iso8601(DateTime.to_date(captured_at))

  defp journal_label(captured_at), do: to_string(captured_at)

  # Captured rows belong to the run they were captured against. A new review, a
  # retry or a fresh compute clears them with a stated reason rather than
  # silently carrying measurements that name another run's decisions.
  defp reset_observation_captures_for_run(socket, %ChangeRun{id: run_id}) do
    case socket.assigns[:observation_captures_run_id] do
      ^run_id ->
        socket

      _other ->
        socket
        |> assign(:observation_captures, %{})
        |> assign(:observation_captures_run_id, run_id)
        |> assign(:observation_form, empty_observation_form())
        |> assign(
          :observation_notice,
          "This is a different review, so measurements captured for the previous one are not carried over."
        )
    end
  end

  defp reset_observation_captures_for_run(socket, _run), do: socket

  defp observation_capture(socket, %Stop{} = station) do
    case Map.get(socket.assigns.observation_captures, station.stop_id) do
      %{input_rows: input_rows, display_rows: display_rows} -> {input_rows, display_rows}
      _other -> {[], []}
    end
  end

  defp stream_observation_rows(socket) do
    {_input_rows, display_rows} =
      case socket.assigns[:observation_station] do
        %Stop{} = station -> observation_capture(socket, station)
        _other -> {[], []}
      end

    stream(socket, :station_observation_rows, Enum.with_index(display_rows), reset: true)
  end

  # The row's position, not its content, is the DOM identity: two accepted rows
  # may legitimately name the same pathway and date.
  defp observation_row_dom_id({_row, index}), do: "station-observation-row-#{index}"

  defp save_station_observation(socket, params) do
    draft = to_form(params, as: :station_observation)

    case socket.assigns[:observation_station] do
      %Stop{} = station ->
        capture_observation(socket, station, params, draft)

      nil ->
        refuse_observation(socket, draft, "Choose a station before capturing a measurement.")
    end
  end

  defp capture_observation(socket, %Stop{} = station, params, draft) do
    case observation_pathway(socket, Map.get(params, "pathway_id")) do
      nil ->
        refuse_observation(socket, draft, "Choose a pathway this review changes.")

      pathway ->
        {input_rows, _display_rows} = observation_capture(socket, station)

        capture_station_observation(
          socket,
          station,
          input_rows ++ [observation_row(pathway.pathway_id, params)],
          draft
        )
    end
  end

  # The measurement is checked against the very context this page installs, so a
  # revoked editor, another station or another run refuses here rather than
  # freezing evidence the helper could never read. One refused row refuses the
  # whole save: a partly captured measurement is not a measurement.
  defp capture_station_observation(socket, %Stop{} = station, rows, draft) do
    case StationAssistant.normalize_observations(AgentPanel.scope(socket), rows) do
      {:ok, normalized, _evidence} ->
        settle_observation(
          socket,
          station,
          rows,
          Map.get(normalized, "rejected", []),
          normalized,
          draft
        )

      {:error, reason} ->
        refuse_observation(socket, draft, observation_refusal_text(reason))
    end
  end

  defp settle_observation(socket, station, rows, [], normalized, _draft) do
    accept_observation(socket, station, rows, normalized)
  end

  defp settle_observation(socket, _station, _rows, rejections, _normalized, draft) do
    refuse_observation(socket, draft, observation_rejection_text(rejections))
  end

  defp observation_refusal_text(:forbidden), do: @permission_error

  defp observation_refusal_text(:no_selected_run),
    do: "Review this station's computed changes before capturing a measurement."

  defp observation_refusal_text(_reason),
    do:
      "This measurement could not be checked against the run. Nothing was changed and your entry is still here."

  defp observation_pathway(socket, pathway_id) when is_binary(pathway_id) and pathway_id != "" do
    Enum.find(socket.assigns[:observation_pathways] || [], &(&1.pathway_id == pathway_id))
  end

  defp observation_pathway(_socket, _pathway_id), do: nil

  # Exactly the row the domain's normalizer accepts: nothing else is read, and a
  # journal note is named by its own id rather than by its text.
  defp observation_row(pathway_id, params) do
    %{
      "source_ref" => observation_source_ref(params),
      "source_revision" => nil,
      "target" => %{"pathway_id" => pathway_id},
      "field" => Map.get(params, "field") || @observation_field,
      "original_value" => Map.get(params, "original_value"),
      "unit" => Map.get(params, "unit"),
      "captured_date" => Map.get(params, "captured_date"),
      "meaning" => Map.get(params, "meaning"),
      "accepted" => Map.get(params, "accepted") == "true",
      "conflict" => Map.get(params, "conflict") == "true"
    }
  end

  defp observation_source_ref(params) do
    case Map.get(params, "journal_entry_id") do
      entry_id when is_binary(entry_id) and entry_id != "" -> entry_id
      _other -> Map.get(params, "source_ref")
    end
  end

  defp accept_observation(socket, %Stop{} = station, input_rows, normalized) do
    display_rows = Map.get(normalized, "observations", [])

    captures =
      Map.put(socket.assigns.observation_captures, station.stop_id, %{
        station: station,
        input_rows: input_rows,
        display_rows: display_rows
      })

    socket
    |> assign(:observation_captures, captures)
    |> assign(:observation_captures_run_id, socket.assigns.change_run.id)
    |> assign(:observation_form, empty_observation_form())
    |> assign(:observation_error, nil)
    |> assign(
      :observation_notice,
      "Captured #{observation_count(length(display_rows))} for #{station.stop_name}. " <>
        "Nothing is approved: the helper can only prepare a review you confirm yourself."
    )
    |> stream_observation_rows()
    |> bind_observation_helper()
  end

  # A refused write keeps the draft and everything already captured, changes no
  # decision status and moves no context: only the reason is added.
  defp refuse_observation(socket, draft, reason) do
    socket
    |> assign(:observation_form, draft)
    |> assign(:observation_error, reason)
    |> assign(:observation_notice, nil)
    |> push_event("focus_first_error", %{selector: "#station-observation-error"})
  end

  defp observation_rejection_text(rejections) do
    detail =
      rejections
      |> Enum.map_join(" ", fn rejection ->
        "Row #{rejection_index(rejection) + 1} (#{rejection_reason_label(rejection)}): " <>
          rejection_reason_text(Map.get(rejection, "reason"))
      end)

    "Nothing was captured, and your entry is still here. #{detail}"
  end

  defp rejection_index(%{"index" => index}) when is_integer(index), do: index
  defp rejection_index(_rejection), do: 0

  defp rejection_reason_label(%{"source_ref" => ref}) when is_binary(ref) and ref != "", do: ref
  defp rejection_reason_label(_rejection), do: "measurement"

  defp rejection_reason_text(reason) do
    Map.get(@observation_rejections, reason) || humanize(reason)
  end

  defp observation_count(1), do: "1 measurement"
  defp observation_count(count), do: "#{count} measurements"

  defp observation_switch_notice(nil, %Stop{} = station) do
    "No measurements captured for #{station.stop_name} yet. The helper summarizes this run until you capture one."
  end

  defp observation_switch_notice(%Stop{stop_id: stop_id}, %Stop{stop_id: stop_id}) do
    nil
  end

  defp observation_switch_notice(%Stop{} = previous, %Stop{} = station) do
    "Measurements captured for #{previous.stop_name} are kept, and are not part of #{station.stop_name}'s helper."
  end

  defp observation_switch_notice(_previous, _station), do: nil

  # The conversation is bound to the station this page selected, the run it is
  # reviewing and the measurements captured for exactly that pair. The snapshot is
  # the existing `station_imports` envelope: this page installs it and
  # `StationAssistant` reads it back, so no second protocol exists (CR-4).
  defp bind_observation_helper(socket) do
    socket |> install_observation_context() |> drop_stale_suggestion()
  end

  # A review read for another station, run or measurement set must not stay open
  # beside a conversation that no longer holds it.
  defp drop_stale_suggestion(%{assigns: %{station_suggestion: %{command: command}}} = socket) do
    case station_imports_source(socket) do
      %{digest: digest} when digest == command.source_digest -> socket
      _other -> close_station_suggestion(socket)
    end
  end

  defp drop_stale_suggestion(socket), do: socket

  defp install_observation_context(socket) do
    context = Scope.context({:version, socket.assigns.current_gtfs_version.id})

    case observation_source_snapshot(socket) do
      {:ok, snapshot} ->
        case Scope.with_source_snapshot(context, snapshot) do
          {:ok, source_context} ->
            socket
            |> assign(:observation_helper_notice, nil)
            |> AgentPanel.set_context(source_context)

          {:error, reason} ->
            socket
            |> assign(:observation_helper_notice, observation_snapshot_notice(reason))
            |> AgentPanel.set_context(context)
        end

      :error ->
        socket
        |> assign(
          :observation_helper_notice,
          "Choose a station to use the import helper. Everything else on this page works without it."
        )
        |> AgentPanel.set_context(context)
    end
  end

  defp observation_source_snapshot(socket) do
    with %Stop{} = station <- socket.assigns[:observation_station],
         %ChangeRun{id: run_id} <- socket.assigns[:change_run],
         true <- ChangeRunReview.computed_review_run?(socket.assigns.change_run) do
      {input_rows, _display_rows} = observation_capture(socket, station)

      {:ok,
       %{
         kind: "station_imports",
         payload: %{
           "station_id" => station.id,
           "station_stop_id" => station.stop_id,
           "change_run_id" => run_id,
           "observations" => input_rows,
           "observations_digest" => StationAssistant.observations_digest(input_rows)
         }
       }}
    else
      _other -> :error
    end
  end

  defp observation_snapshot_notice(:too_large) do
    "These measurements are larger than the helper can read, so it was not connected. " <>
      "They stay listed here and nothing was changed."
  end

  defp observation_snapshot_notice(_reason) do
    "The helper could not be connected to these measurements, so it was left off. " <>
      "Everything else on this page works without it."
  end

  # -- Suggested decisions reviewed and confirmed --------------------------

  # The suggestion a person is reading is page state, not conversation state: it
  # names the exact entry it came from, the exact command that entry stored, and
  # the rows this page resolved out of its own review. Nothing else survives a
  # reload, and nothing here is derived from the conversation afterwards.
  defp assign_station_suggestion(socket, suggestion) do
    socket
    |> assign(:station_suggestion, suggestion)
    |> assign(:station_suggestion_error, nil)
    |> assign(:station_suggestion_status, nil)
    |> assign(
      :station_suggestion_return_focus,
      suggestion && Map.get(suggestion, :return_focus_id)
    )
  end

  # A forged entry id never reaches the session: a value that is not an integer
  # is ignored, exactly as a stale or unknown entry is.
  defp open_station_suggestion(socket, id) do
    case Integer.parse(to_string(id)) do
      {entry_id, ""} when entry_id > 0 -> handoff_station_suggestion(socket, entry_id)
      _other -> socket
    end
  end

  defp handoff_station_suggestion(socket, entry_id) do
    case Agents.prepared(
           socket.assigns.agent_session,
           socket.assigns.agent_conversation_id,
           entry_id
         ) do
      {:ok, %{command: %{kind: :station_import_selection} = command}} ->
        review_station_suggestion(socket, entry_id, command)

      _stale_or_unknown ->
        assign(socket, :agent_notice, @prepared_missing_notice)
    end
  end

  # The review is regenerated from the page's own frozen snapshot and the exact
  # prepared command, so what the reviewer reads is what Confirm will ask the
  # domain to approve (the CalendarsLive precedent). A command for another run,
  # another station or another frozen source is one refusal, and the stored
  # proposal is released only by an exact confirmation.
  defp review_station_suggestion(socket, entry_id, command) do
    socket
    |> reject_foreign_suggestion(command)
    |> case do
      {:error, socket} ->
        socket

      {:ok, socket} ->
        open_suggestion_review(socket, entry_id, command)
    end
  end

  # The prepared command must describe this page's current station and run, and
  # must have been produced against the very snapshot this page still holds.
  defp reject_foreign_suggestion(socket, command) do
    snapshot = station_imports_source(socket)

    matches? =
      is_map(snapshot) and Map.get(snapshot, :kind) == "station_imports" and
        Map.get(command, :source_digest) == Map.get(snapshot, :digest) and
        Map.get(command, :run_id) == change_run_id(socket) and
        Map.get(command, :station_id) == observation_station_id(socket)

    if matches? do
      {:ok, socket}
    else
      {:error, assign(socket, :agent_notice, @prepared_missing_notice)}
    end
  end

  # Each row is regenerated from the page's own frozen snapshot through the same
  # projection the helper used, and each row's `decision_digest` must still be the
  # one the prepared command named. A decision the run no longer holds, or one
  # whose values moved after the suggestion was prepared, recomputes to something
  # else - so the whole review is refused rather than showing a row that is not
  # what would be approved (INV-1).
  defp open_suggestion_review(socket, entry_id, command) do
    ids =
      Enum.map(Map.get(command, :decisions) || [], &Map.get(&1, "decision_id"))

    case StationAssistant.prepare_import_selection(AgentPanel.scope(socket), ids) do
      {:ok, answer, _evidence} ->
        if answer["input_digest"] == Map.get(command, :input_digest) and
             answer["selected"] != [] and answer["unresolved"] == [] and answer["excluded"] == [] do
          assign_station_suggestion(socket, %{
            entry_id: entry_id,
            command: command,
            rows: Enum.map(answer["selected"], &suggestion_row/1),
            station_stop_id: answer["station_stop_id"],
            return_focus_id: "agent-prepared-#{entry_id}"
          })
          |> focus_suggestion("station-suggestion-confirm")
        else
          assign(socket, :agent_notice, @prepared_missing_notice)
        end

      {:error, _reason} ->
        assign(socket, :agent_notice, @prepared_missing_notice)
    end
  end

  # What the reviewer reads is the server's own row: the decision id, the old and
  # new width, the captured measurement it was reviewed against, and every field
  # that decision changes.
  defp suggestion_row(row) do
    %{
      decision_id: row["decision_id"],
      decision_digest: row["decision_digest"],
      subject: "Pathway #{row["natural_key"]}",
      current_width: to_string(row["current_value"]),
      uploaded_width: to_string(row["uploaded_value"]),
      captured_source: observation_source_label(row["observation"])
    }
  end

  # What the reviewer needs of a captured source: what was measured, in what
  # unit, when, and where it came from. A journal-backed reference is named by
  # identity only - its body and photos stay on the station page.
  defp observation_source_label(%{} = observation) do
    "Measured #{observation["original_value"]} #{observation["unit"]} on " <>
      "#{observation["captured_date"]} · source #{observation["source_ref"]}"
  end

  defp observation_source_label(_other), do: nil

  defp observation_station_id(socket) do
    case socket.assigns[:observation_station] do
      %Stop{id: id} -> id
      _other -> nil
    end
  end

  defp change_run_id(socket) do
    case socket.assigns[:change_run] do
      %ChangeRun{id: id} -> id
      _other -> nil
    end
  end

  defp station_imports_source(socket) do
    case Scope.source_snapshot(AgentPanel.scope(socket)) do
      %{kind: "station_imports"} = snapshot -> snapshot
      _other -> nil
    end
  end

  # Confirming asks the domain to approve exactly the reviewed rows and to record
  # the captured provenance beside them. The page never writes a status itself,
  # never records a receipt for the helper (only statuses were confirmed, not an
  # apply) and never relies on what the conversation said afterwards.
  defp confirm_station_suggestion(%{assigns: %{station_suggestion: nil}} = socket), do: socket

  defp confirm_station_suggestion(socket) do
    suggestion = socket.assigns.station_suggestion

    case station_imports_source(socket) do
      %{kind: "station_imports"} = source ->
        selection = suggestion_selection(suggestion, source)

        case ChangeRuns.confirm_observation_selection(
               socket.assigns.current_organization.id,
               socket.assigns.current_gtfs_version.id,
               socket.assigns.current_user,
               source,
               selection
             ) do
          {:ok, %{decisions: decisions}} ->
            socket
            |> assign(:station_suggestion_status, %{
              kind: :confirmed,
              title: "Nothing has been applied yet.",
              message:
                "#{approved_label_for(decisions)} approved with the measurement each one was " <>
                  "reviewed against. Review the whole approved list, then choose Apply decisions."
            })
            |> close_station_suggestion()
            |> refresh_change_review()
            |> focus_suggestion("station-approved-apply-scope")

          {:error, reason} ->
            # A refusal changes no status and keeps the review and every draft, so
            # the person can decide again against the same rows.
            socket
            |> assign(:station_suggestion_error, suggestion_refusal_text(reason))
            |> focus_suggestion("station-suggestion-confirm")
        end

      _other ->
        socket
        |> assign(:station_suggestion_error, @prepared_missing_notice)
        |> focus_suggestion("station-suggestion-confirm")
    end
  end

  defp suggestion_selection(suggestion, source) do
    command = suggestion.command

    %{
      "run_id" => Map.get(command, :run_id),
      "station_stop_id" => Map.get(source.payload, "station_stop_id"),
      "input_digest" => Map.get(command, :input_digest),
      "decisions" =>
        Enum.map(suggestion.rows, fn row ->
          %{"decision_id" => row.decision_id, "decision_digest" => row.decision_digest}
        end)
    }
  end

  defp approved_label_for([_decision]), do: "1 change is"
  defp approved_label_for(decisions), do: "#{length(decisions)} changes are"

  defp suggestion_refusal_text(:forbidden), do: @permission_error

  defp suggestion_refusal_text(:evidence_limit),
    do:
      "This review has recorded as much captured evidence as it keeps. Nothing was approved and " <>
        "your measurements are still here."

  defp suggestion_refusal_text(:invalid_selection),
    do:
      "That suggestion cannot be confirmed as asked. Nothing was approved, and the review is " <>
        "still here."

  defp suggestion_refusal_text(_reason),
    do:
      "This review changed after the suggestion was prepared, so nothing was approved. The review " <>
        "and your measurements are still here - ask the helper to prepare it again."

  # Closing drops the page's own copy and hands focus back to the card the review
  # came from. The entry's stored proposal stays exactly as it was: it is the
  # conversation's, and only an exact confirmation releases it.
  defp close_station_suggestion(socket) do
    socket
    |> assign(:station_suggestion, nil)
    |> assign(:station_suggestion_error, nil)
  end

  # Focus goes back to the card the review was opened from, which is still in the
  # transcript: cancelling released nothing, so the entry that offered the
  # decision is exactly where the person should be. The helper's own open control
  # is the fallback when no review was open.
  defp cancel_station_suggestion(%{assigns: %{station_suggestion: nil}} = socket) do
    assign(socket, :station_suggestion_return_focus, nil)
  end

  defp cancel_station_suggestion(socket) do
    assign(
      socket,
      :station_suggestion_return_focus,
      socket.assigns.station_suggestion.return_focus_id
    )
    |> close_station_suggestion()
  end

  defp focus_suggestion_return(%{assigns: %{station_suggestion_return_focus: id}} = socket)
       when is_binary(id),
       do: push_event(socket, "focus_station_target", %{id: id})

  defp focus_suggestion_return(socket), do: focus_suggestion(socket, "station-helper-open")

  defp focus_suggestion(socket, id) when is_binary(id) and id != "",
    do: push_event(socket, "focus_station_target", %{id: id})

  defp focus_suggestion(socket, _other), do: socket

  defp empty_observation_form do
    to_form(
      %{
        "pathway_id" => nil,
        "original_value" => "",
        "unit" => "cm",
        "captured_date" => Date.utc_today() |> Date.to_iso8601(),
        "meaning" => @observation_meaning,
        "source_ref" => "",
        "journal_entry_id" => "",
        "accepted" => "true",
        "conflict" => "false"
      },
      as: :station_observation
    )
  end

  defp update_change_decision(socket, decision_id, status) do
    with %ChangeRun{} = run <- socket.assigns[:change_run],
         {:ok, _decision} <-
           ChangeRuns.set_decision_status(
             socket.assigns.current_organization.id,
             run.id,
             decision_id,
             status
           ) do
      refresh_change_review(socket)
    else
      _ -> socket
    end
  end

  defp request_change_apply(socket) do
    with %ChangeRun{} = run <- socket.assigns[:change_run],
         {:ok, pending} <-
           ChangeRuns.request_apply(
             socket.assigns.current_organization.id,
             run.id,
             socket.assigns.current_user
           ) do
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ChangeRuns.topic(pending))
      {socket, pending} = start_change_runner(socket, :apply, pending)
      socket |> assign(:change_run, pending) |> refresh_change_review()
    else
      {:error, :forbidden} -> put_flash(socket, :error, @permission_error)
      _ -> socket
    end
  end

  defp cancel_change_run(socket) do
    with %ChangeRun{} = run <- socket.assigns[:change_run],
         {:ok, changed} <-
           ChangeRuns.request_cancel(
             socket.assigns.current_organization.id,
             run.id,
             socket.assigns.current_user
           ) do
      socket |> assign(:change_run, changed) |> refresh_change_review()
    else
      {:error, :forbidden} -> put_flash(socket, :error, @permission_error)
      _ -> socket
    end
  end

  defp retry_change_run(socket) do
    with %ChangeRun{} = run <- socket.assigns[:change_run],
         {:ok, retry} <-
           ChangeRuns.retry(
             socket.assigns.current_organization.id,
             run.id,
             socket.assigns.current_user
           ) do
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ChangeRuns.topic(retry))

      {socket, retry} =
        case retry.state do
          :pending_apply -> start_change_runner(socket, :apply, retry)
          :pending_compute -> start_change_runner(socket, :compute, retry)
          _ -> {socket, retry}
        end

      socket |> assign(:change_run, retry) |> refresh_change_review()
    else
      {:error, :forbidden} -> put_flash(socket, :error, @permission_error)
      _ -> socket
    end
  end

  defp filter_decisions(decisions, :all), do: decisions
  defp filter_decisions(decisions, action), do: Enum.filter(decisions, &(&1.action == action))

  # The page opens on the workflow that has something to decide. A review that is
  # running, waiting for approval or stopped is that; one that finished is done
  # with, so it does not stand between a person and the common job, a feed.
  defp opening_source(change_run) do
    if diff_step(change_run) in [:upload, :done], do: :feed, else: :station
  end

  defp diff_step(nil), do: :upload
  defp diff_step(%ChangeRun{state: :review}), do: :review
  defp diff_step(%ChangeRun{state: :completed}), do: :done
  defp diff_step(%ChangeRun{}), do: :processing

  defp run_summary(nil), do: empty_diff_summary()

  defp run_summary(%ChangeRun{summary: summary}) when is_map(summary) do
    Enum.reduce([:add, :modify, :remove, :conflict], empty_diff_summary(), fn key, acc ->
      Map.put(acc, key, Map.get(summary, Atom.to_string(key), Map.get(summary, key, 0)))
    end)
  end

  # Station merge ignores `pathway_evolutions.txt`; the count the compute step
  # stored in the durable summary is what lets the review disclose that the
  # upload carried it. A run from before the count existed has no key.
  defp ignored_evolution_files(%ChangeRun{summary: summary}) when is_map(summary),
    do: Map.get(summary, "ignored_evolution_files", 0) || 0

  defp ignored_evolution_files(_run), do: 0

  # The omission disclosure is durable run state, so the review, a stopped run
  # and the finished result all render it from the same summary.
  defp ignored_closures_notice(assigns) do
    ~H"""
    <.message
      id="diff-evolutions-ignored"
      kind="info"
      title="Closures in this upload stay as they are"
    >
      <code class="font-mono text-[13px]">pathway_evolutions.txt</code>
      is not applied by station merge. Existing scheduled closures are unchanged.
    </.message>
    """
  end

  defp run_blockers(%ChangeRun{state: :review}), do: []
  defp run_blockers(%ChangeRun{state: :failed, failure_code: code}), do: [%{reason: code}]
  defp run_blockers(_), do: []

  defp run_diagnostics(%ChangeRun{diagnostics: diagnostics}) when is_list(diagnostics),
    do: diagnostics

  defp run_diagnostics(_), do: []

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :view, view_state(assigns))

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
        <.gtfs_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:import} />
      </:sub_header>

      <div id="import-page" class="ds-page" phx-hook=".ImportErrorFocus">
        <.header>
          Import data
          <:subtitle>
            Add a new version from a feed, or apply station changes to {version_display_name(
              @current_gtfs_version
            )}.
          </:subtitle>
        </.header>

        <%!-- Reconnect-safe recovery region: streamed, stable DOM ids, one ARIA
             live region announces each state change once. It sits outside the
             list card so it exists before the first announcement. --%>
        <div id="gtfs-import-recovery-announce" aria-live="polite">
          <%= if @recovery_announce do %>
            <span class="sr-only">{@recovery_announce}</span>
          <% end %>
        </div>

        <%!-- Imports that stopped come first: a stopped import blocks its version
             name, so the decision about it comes before the form. The card stays
             mounted, hidden, so the stream always has its container. --%>
        <.card
          id="import-recovery-section"
          title="Unfinished imports"
          subtitle={"Imports that are running or stopped before they published. Anyone in #{@current_organization.name} can publish or delete them."}
          class="mb-6"
          hidden={@recovery_empty}
        >
          <div :if={@recovery_error} class="border-b border-subtle px-5 py-4">
            <.message id="import-recovery-error" kind="warning" title="Nothing was deleted">
              {@recovery_error}
            </.message>
          </div>
          <ul
            id="import-recovery-runs"
            phx-update="stream"
            class="m-0 list-none divide-y divide-subtle p-0"
          >
            <.run_row
              :for={{dom_id, run} <- @streams.import_recovery_runs}
              id={dom_id}
              run={run}
              processing_publish={@processing_publish}
              discardable?={discardable?(run)}
            />
          </ul>
        </.card>

        <div class="flex flex-col gap-6 lg:flex-row lg:items-start">
          <div class="grid min-w-0 flex-1 grid-cols-1 gap-6">
            <.card
              id="import-workspace"
              title={workspace_title(@source)}
              subtitle={workspace_subtitle(@source, @current_gtfs_version)}
              hidden={!@view.form?}
            >
              <div class="grid grid-cols-1 gap-5 px-5 py-5">
                <form id="import-source-form" phx-change="select_source" class="m-0">
                  <.source_cards
                    id="import-source"
                    name="source"
                    label="What are you importing?"
                    options={source_options()}
                    selected={to_string(@source)}
                  />
                </form>

                <.feed_form
                  form={@form}
                  upload={@uploads.gtfs_files}
                  result={@import_result}
                  importing={@importing}
                  discarded_name={@discarded_name}
                  skipped={@unrecognized_upload_files}
                  version={@current_gtfs_version}
                  organization={@current_organization}
                  hidden={@source != :feed}
                />

                <.station_form
                  form={@diff_form}
                  upload={@uploads.diff_files}
                  diff_step={@diff_step}
                  blockers={@diff_blockers}
                  version={@current_gtfs_version}
                  hidden={@source != :station}
                />
              </div>
            </.card>

            <%!-- One quiet sentence of progress for assistive technology; the card
                 below carries the visual one. --%>
            <div id="gtfs-import-status" aria-live="polite" role="status" class="sr-only">
              <%= if @importing do %>
                Importing “{target_name(@import_target)}”.<%= if @import_progress do %>
                  Reading {@import_progress.file}.
                <% end %>
              <% end %>
            </div>

            <.importing_card :if={@importing} target={@import_target} progress={@import_progress} />

            <.feed_result
              :if={match?({:ok, _, _}, @import_result)}
              result={@import_result}
              health={@import_agency_health}
              left_out={@import_left_out}
              version={@current_gtfs_version}
            />

            <.station_panel
              :if={@source == :station and @diff_step != :upload}
              step={@diff_step}
              run={@change_run}
              summary={@diff_summary}
              blockers={@diff_blockers}
              filter={@diff_filter}
              decisions={@decisions_by_id}
              dependents={@decision_dependents}
              parse_failures={@diff_parse_failures}
              preview_count={@diff_preview_count}
              decisions_stream={@streams.diff_decisions}
              previews_stream={@streams.diff_preview_decisions}
              observation_stations={@observation_stations}
              observation_station={@observation_station}
              observation_scope_form={@observation_scope_form}
              observation_form={@observation_form}
              observation_pathways={@observation_pathways}
              observation_journal_entries={@observation_journal_entries}
              observation_captures={@observation_captures}
              observation_error={@observation_error}
              observation_notice={@observation_notice}
              observation_helper_notice={@observation_helper_notice}
              agent_open?={@agent_open?}
              station_suggestion={@station_suggestion}
              station_suggestion_error={@station_suggestion_error}
              station_suggestion_status={@station_suggestion_status}
              version={@current_gtfs_version}
              evolution_targets={@evolution_targets}
            />

            <.card
              :if={@source == :station and @diff_step == :review}
              id="station-observations"
              title="Accepted width measurements"
              subtitle="Widths staff already measured. Recording one approves and applies nothing."
            >
              <.station_observation_section
                stations={@observation_stations}
                station={@observation_station}
                scope_form={@observation_scope_form}
                form={@observation_form}
                pathways={@observation_pathways}
                journal_entries={@observation_journal_entries}
                rows_stream={@streams.station_observation_rows}
                captures={@observation_captures}
                error={@observation_error}
                notice={@observation_notice}
                helper_notice={@observation_helper_notice}
                open?={@agent_open?}
              />
            </.card>

            <div :if={@source == :station and @diff_step == :review and @agent_open?} class="min-w-0">
              <.agent_panel
                id="agent-panel"
                title={@agent_title}
                intro={@agent_intro}
                examples={@agent_examples}
                scope_line={"Station import · " <> @current_gtfs_version.name}
                status={@agent_status}
                entries={@streams.agent_entries}
                form={@agent_form}
                notice={@agent_notice}
                entries_empty?={@agent_entries_empty?}
                composer_hint="This helper reads this station's import run and prepares a review of the measurements you captured. It can't approve or apply anything."
              />
            </div>

            <section
              :if={@recovery_empty and @view.form?}
              id="import-recovery-empty"
              aria-labelledby="import-recovery-empty-title"
              class="rounded-card border border-subtle px-5 py-4"
            >
              <h2
                id="import-recovery-empty-title"
                class="text-[15px] font-bold leading-snug text-strong"
              >
                Unfinished imports
              </h2>
              <p class="mt-0.5 text-[13px] text-muted">
                None. If an import stops before it publishes, it appears here so you can publish or delete it.
              </p>
            </section>
          </div>

          <.feed_aside
            :if={@view.aside == :feed}
            version={@current_gtfs_version}
            organization={@current_organization}
          />
          <.station_aside :if={@view.aside == :station} version={@current_gtfs_version} />
        </div>

        <%!-- Deleting a failed version removes the version and what it imported,
             so it is confirmed in a dialog that names it. "Keep version" takes
             initial focus and the opening button gets focus back. --%>
        <.confirm_dialog
          id="import-discard-dialog"
          chrome="planner"
          confirm_variant="primary"
          open={@pending_discard_run_id != nil}
          title="Delete failed version?"
          confirm_label="Delete failed version"
          pending_label="Deleting…"
          cancel_label="Keep version"
          on_confirm={JS.push("delete_version", value: %{run_id: @pending_discard_run_id})}
          on_cancel="cancel_discard"
          return_focus_id={@pending_discard_run_id && "discard-#{@pending_discard_run_id}"}
          described_by="import-discard-dialog-body"
        >
          “{@pending_discard_name}” stopped before it was published. Deleting removes this version and everything it imported. Versions you’ve published aren’t affected.
        </.confirm_dialog>
      </div>
    </Layouts.app>

    <%!-- Move focus to the first invalid field when validation produces an error,
         using a colocated hook (no embedded script) so keyboard and screen-reader
         users land on the fixable control. The same hook carries focus back to the
         helper card a prepared review was opened from, and to the review's own
         controls when it opens, closes or is refused. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ImportErrorFocus">
      export default {
        mounted() {
          // LiveView puts focus back on the control a submit came from right
          // after the patch, so the move waits one frame to land last.
          const focusLater = (el) => {
            if (el) window.requestAnimationFrame(() => el.focus())
          }
          this.handleEvent("focus_first_error", ({selector}) => {
            focusLater(this.el.querySelector(selector))
          })
          this.handleEvent("focus_station_target", ({id}) => {
            focusLater(this.el.querySelector(`#${CSS.escape(id)}`))
          })
          this.handleEvent("focus_gtfs_import_files", () => {
            const el = this.el.querySelector("#gtfs-import-upload-input input")
            if (el) el.focus()
          })
          this.handleEvent("focus_diff_files", () => {
            const el = this.el.querySelector("#diff-upload-input input")
            if (el) el.focus()
          })
        }
      }
    </script>
    """
  end

  # What is on screen. The form is shown while its workflow has nothing running
  # or finished to report; the aside explains a workflow while it is being set up
  # or is running, and steps aside for a result or a review, which need the width.
  defp view_state(assigns), do: %{form?: form?(assigns), aside: aside(assigns)}

  defp form?(%{source: :feed} = assigns),
    do: not assigns.importing and not match?({:ok, _, _}, assigns.import_result)

  defp form?(%{source: :station} = assigns), do: assigns.diff_step == :upload

  defp aside(%{source: :feed} = assigns), do: if(form?(assigns), do: :feed, else: :none)
  defp aside(%{source: :station, diff_step: :upload}), do: :station

  defp aside(%{source: :station} = assigns),
    do: if(progress_run?(assigns), do: :station, else: :none)

  defp progress_run?(%{diff_step: :processing, change_run: %ChangeRun{state: state}}),
    do: state in [:pending_compute, :computing, :pending_apply, :applying]

  defp progress_run?(_assigns), do: false

  defp source_options, do: @source_options

  defp workspace_title(:feed), do: "Import a feed"
  defp workspace_title(:station), do: "Update station data"

  defp workspace_subtitle(:feed, version),
    do: "Creates a new version. #{version_display_name(version)} isn’t changed."

  defp workspace_subtitle(:station, version),
    do: "Edits #{version_display_name(version)}, after you approve each change."

  # ── Feed workflow ─────────────────────────────────────────────────────────

  attr :form, :any, required: true
  attr :upload, :any, required: true
  attr :result, :any, default: nil
  attr :importing, :boolean, required: true
  attr :discarded_name, :string, default: nil
  attr :skipped, :list, default: []
  attr :version, :any, required: true
  attr :organization, :any, required: true
  attr :hidden, :boolean, default: false

  defp feed_form(assigns) do
    assigns = assign(assigns, :entries, assigns.upload.entries)

    ~H"""
    <.form
      for={@form}
      id="gtfs-import-form"
      class="grid grid-cols-1 gap-5"
      phx-change="validate"
      phx-submit="import"
      hidden={@hidden}
    >
      <.message
        :if={@discarded_name}
        id="gtfs-import-discarded"
        kind="success"
        title={"Deleted the failed version “#{@discarded_name}”."}
      >
        Its name is back in the form. Choose the feed again to retry.
      </.message>

      <.feed_error :if={match?({:error, _, _}, @result)} result={@result} version={@version} />

      <.dropzone
        id="gtfs-import-upload"
        upload={@upload}
        label="Feed files"
        help="One .zip, or up to 50 .txt or .csv files. Each file can be up to 200 MB. A .zip uploads faster."
        action="Choose a .zip file"
        hint="or drag it here"
        cancel_event="cancel-upload"
        skipped={@skipped}
      />

      <.message
        :if={@skipped != []}
        id="gtfs-import-unrecognized"
        kind="warning"
        title={skipped_title(@skipped)}
      >
        {Enum.join(@skipped, ", ")}. This import only reads GTFS feed files.
        <span :if={tods_pointer?(@organization)}>
          Garage and vehicle files (TODS) are imported from
          <.text_link
            navigate={~p"/gtfs/#{@version.id}/settings/fleet"}
            label="Fleet"
            class="font-semibold underline"
          /> and
          <.text_link
            navigate={~p"/gtfs/#{@version.id}/settings/garages"}
            label="Garages"
            class="font-semibold underline"
          />.
        </span>
      </.message>

      <.input
        id="gtfs-import-version-name"
        field={@form[:version_name]}
        label="Version name"
        placeholder="e.g., October 2026 service"
        help="Appears in the version menu. It must differ from your other versions."
        maxlength="255"
        autocomplete="off"
        phx-blur="version_name_blur"
      />

      <%!-- What Import will do, before the button: the version it creates, what it
           reads, what it leaves alone and when it publishes. --%>
      <dl
        :if={@entries != []}
        id="gtfs-import-summary"
        class="m-0 grid gap-x-4 gap-y-1.5 rounded-control border border-subtle bg-canvas px-4 py-3 text-sm sm:grid-cols-[5.5rem_minmax(0,1fr)]"
      >
        <dt class="text-muted">Creates</dt>
        <dd class="m-0 min-w-0 font-semibold text-strong [overflow-wrap:anywhere]">
          {creates_summary(@form)}
        </dd>
        <dt class="text-muted">Reads</dt>
        <dd class="m-0 min-w-0 text-default [overflow-wrap:anywhere]">
          {reads_summary(@upload, @skipped)}
        </dd>
        <dt class="text-muted">Keeps</dt>
        <dd class="m-0 min-w-0 text-default">{version_display_name(@version)} unchanged</dd>
        <dt class="text-muted">Then</dt>
        <dd class="m-0 min-w-0 text-default">
          Publishes the new version when the import finishes. If anything fails, nothing is published.
        </dd>
      </dl>

      <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
        <.button
          id="gtfs-import-submit"
          type="submit"
          class="min-h-11"
          disabled={@entries == [] || @importing}
          data-unavailable={@entries == [] && !@importing}
        >
          <%= if @importing do %>
            <span class="loading loading-spinner loading-sm"></span> Importing…
          <% else %>
            Import feed
          <% end %>
        </.button>
        <p id="gtfs-import-reason" class="m-0 text-[13px] text-muted">
          {if @entries == [],
            do: "Choose a feed file to import.",
            else: "You can’t cancel an import once it starts."}
        </p>
      </div>
    </.form>
    """
  end

  # The one place a feed import can fail before a run exists to report on it: a
  # submit with nothing chosen, or an upload the server could not read back.
  attr :result, :any, required: true
  attr :version, :any, required: true

  defp feed_error(%{result: {:error, nil, :no_files_selected}} = assigns) do
    ~H"""
    <.message id="gtfs-import-result" kind="error" title="Choose a file to import.">
      Select at least one file to import.
    </.message>
    """
  end

  defp feed_error(%{result: {:error, target, {:publication_failed, _reason}}} = assigns) do
    assigns = assign(assigns, :target, target)

    ~H"""
    <.message
      id="gtfs-import-result"
      kind="error"
      title={"“#{target_name(@target)}” wasn’t published."}
    >
      Version “{target_name(@target)}” finished importing but could not be published. Use Unfinished imports above to publish it again or delete it.
    </.message>
    """
  end

  defp feed_error(%{result: {:error, target, reason}} = assigns) do
    assigns = assign(assigns, target: target, reason: reason)

    ~H"""
    <.message
      id="gtfs-import-result"
      kind="error"
      title={"“#{target_name(@target)}” wasn’t imported."}
    >
      Nothing was published, and {version_display_name(@version)} is unchanged.
      <%= case @reason do %>
        <% {:upload_consumption_failed, :artifact_capacity_exceeded} -> %>
          These files exceed the import storage limit. Upload fewer or smaller files.
        <% {:upload_consumption_failed, detail} -> %>
          We couldn’t read the uploaded files. Choose them again and retry.
          <details class="mt-1">
            <summary class="cursor-pointer font-semibold">Technical details</summary>
            <p class="m-0 mt-1 font-mono text-[13px] [overflow-wrap:anywhere]">{inspect(detail)}</p>
          </details>
        <% :import_not_finished -> %>
          The import did not finish. Use Unfinished imports above to delete it and try again.
        <% _reason -> %>
          Choose the files again and retry.
      <% end %>
    </.message>
    """
  end

  attr :target, :any, default: nil
  attr :progress, :any, default: nil

  defp importing_card(assigns) do
    ~H"""
    <.card
      id="gtfs-importing-card"
      title={"Importing “#{target_name(@target)}”"}
      subtitle="Reading your files into a new version."
    >
      <:badge>
        <.tone_badge class="whitespace-nowrap" tone="info" icon="hero-arrow-path" spin>
          In progress
        </.tone_badge>
      </:badge>
      <div class="grid grid-cols-1 gap-5 px-5 py-5">
        <div :if={@progress} id="gtfs-import-progress">
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <p class="text-sm font-semibold text-strong [overflow-wrap:anywhere]">
              Reading {@progress.file}
            </p>
            <p class="text-[13px] tabular-nums text-muted">
              {Wording.count(@progress.processed)} of {Wording.count(@progress.total)} rows
            </p>
          </div>
          <div
            class="mt-2 h-2.5 overflow-hidden rounded-badge bg-canvas"
            role="progressbar"
            aria-label={"Rows read from #{@progress.file}"}
            aria-valuemin="0"
            aria-valuemax="100"
            aria-valuenow={progress_percent(@progress.processed, @progress.total)}
          >
            <div
              class="h-full bg-info-line"
              style={"width: #{progress_percent(@progress.processed, @progress.total)}%"}
            >
            </div>
          </div>
        </div>
        <p :if={!@progress} class="m-0 text-sm text-default">Starting the import…</p>
        <p class="m-0 text-[13px] text-muted">
          You can leave this page. The import keeps running, and it’s listed under Unfinished imports if it stops. An import can’t be cancelled once it starts.
        </p>
      </div>
    </.card>
    """
  end

  # What came in, and what to check before sharing it. "Open new version" is the
  # one primary; the agency findings are the only conditional part.
  attr :result, :any, required: true
  attr :health, :any, default: nil
  attr :left_out, :list, default: []
  attr :version, :any, required: true

  defp feed_result(%{result: {:ok, published, %Import.Result{} = result}} = assigns) do
    assigns =
      assigns
      |> assign(:published, published)
      |> assign(:counts, result.counts)
      |> assign(:unrecognized, result.unrecognized_files)

    ~H"""
    <section
      id="gtfs-import-result"
      aria-labelledby="gtfs-import-result-title"
      aria-live="assertive"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-start justify-between gap-x-6 gap-y-4 border-b border-subtle px-5 py-5">
        <div class="flex min-w-0 items-start gap-3">
          <span class="mt-0.5 grid size-8 shrink-0 place-items-center rounded-full bg-success-bg text-success-fg">
            <.icon name="hero-check" class="size-4" />
          </span>
          <div class="min-w-0">
            <h2
              id="gtfs-import-result-title"
              class="font-display text-[24px] font-semibold leading-tight tracking-[-0.025em] text-strong [overflow-wrap:anywhere]"
            >
              Imported “{@published.name}”
            </h2>
            <p class="mt-1.5 text-sm text-default">
              The new version is published and ready to open. {version_display_name(@version)} is unchanged.
            </p>
          </div>
        </div>
        <.button
          id="gtfs-import-view-version"
          navigate={~p"/gtfs/#{@published.id}/routes"}
          class="min-h-11"
        >
          Open new version
        </.button>
      </div>

      <div class="px-5 py-5">
        <.figures
          id="gtfs-import-counts"
          class="max-w-xl grid-cols-3"
          items={[
            {"gtfs-import-count-levels", "Levels", Map.get(@counts, :levels, 0)},
            {"gtfs-import-count-stops", "Stops", Map.get(@counts, :stops, 0)},
            {"gtfs-import-count-pathways", "Pathways", Map.get(@counts, :pathways, 0)}
          ]}
        />
      </div>

      <p
        :if={@unrecognized != []}
        id="gtfs-import-skipped"
        class="m-0 border-t border-subtle px-5 py-4 text-[13px] text-default"
      >
        <span class="font-semibold text-strong">Skipped files this import doesn’t use:</span>
        {Enum.join(@unrecognized, ", ")}.
      </p>

      <.agency_findings :if={@health} health={@health} version_id={@published.id} />

      <.left_out_block groups={@left_out} version_id={@published.id} />

      <div class="flex flex-wrap items-center gap-x-5 gap-y-1 border-t border-subtle bg-canvas px-5 py-3 text-sm">
        <.link
          id="gtfs-import-check-version"
          navigate={~p"/gtfs/#{@published.id}/export"}
          class="inline-flex min-h-11 items-center font-semibold text-action hover:underline"
        >
          Check the new version for problems
        </.link>
        <.button
          id="gtfs-import-another"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="import_another"
        >
          Import another feed
        </.button>
      </div>
    </section>
    """
  end

  # Names the decisions a partial run could not apply. The list is capped so a
  # feed-wide failure stays readable.
  attr :decisions, :list, required: true
  attr :targets, :map, default: %{}, doc: "owning stations of pathways that closures protect"
  attr :version_id, :any, default: nil

  defp failed_decisions_list(assigns) do
    assigns =
      assigns
      |> assign(:shown, Enum.take(assigns.decisions, @max_failed_decisions))
      |> assign(:hidden_count, max(length(assigns.decisions) - @max_failed_decisions, 0))

    ~H"""
    <ul
      :if={@decisions != []}
      id="diff-failed-decisions"
      class="m-0 list-none space-y-1 p-0 text-sm text-default"
    >
      <li :for={decision <- @shown} data-decision-id={decision.decision_id}>
        <span class="font-medium">
          <span class="capitalize">{decision.entity_type}</span> {decision.natural_key}
        </span>
        · {decision.action} · {decision_failure_reason(decision)}
        <.link
          :for={target <- Map.get(@targets, decision.decision_id, [])}
          data-role="version-diff-evolutions-link"
          data-pathway-id={decision.natural_key}
          data-station-stop-id={target.stop_id}
          navigate={evolutions_href(@version_id, target.stop_id, decision.natural_key)}
          class="ml-1 inline-flex min-h-11 items-center gap-1 font-semibold text-action hover:underline"
        >
          Open closures · {target.stop_name}
          <.icon name="hero-arrow-right" class="size-4 shrink-0" />
        </.link>
      </li>
      <li :if={@hidden_count > 0} id="diff-failed-decisions-more">and {@hidden_count} more</li>
    </ul>
    """
  end

  # The import success result's agency findings (AC-27). They sit below the
  # counts and never replace or delay the success, and only this element is
  # conditional: a clean feed publishes with no findings element. Each link
  # targets the published version's own Agencies page, so `/gtfs/<published
  # id>/settings/agencies` and not the version in the URL.
  attr :health, :map, required: true
  attr :version_id, :string, required: true

  defp agency_findings(assigns) do
    ~H"""
    <div
      :if={findings?(@health)}
      id="gtfs-import-agency-findings"
      class="grid gap-3 border-t border-subtle px-5 py-4"
    >
      <p class="m-0 text-[13px] font-semibold text-strong">Check before you export</p>
      <.message :if={@health.agency_count == 0} kind="warning" title="No agency in this feed">
        <span :if={@health.unassigned_routes > 0}>
          {unassigned_routes_sentence(@health.unassigned_routes)}
        </span>
        <:action>
          <.button
            id="gtfs-import-set-up-agency"
            variant="secondary"
            class="min-h-11"
            navigate={~p"/gtfs/#{@version_id}/settings/agencies"}
          >
            Set up agency
          </.button>
        </:action>
      </.message>

      <.message
        :if={@health.agency_count > 0 and unresolved_zone?(@health.zone)}
        kind="warning"
        title={zone_finding_title(@health.zone)}
      >
        Choose one timezone for this version.
        <:action>
          <.button
            id="gtfs-import-resolve-timezones"
            variant="secondary"
            class="min-h-11"
            navigate={~p"/gtfs/#{@version_id}/settings/agencies"}
          >
            Resolve timezones
          </.button>
        </:action>
      </.message>
    </div>
    """
  end

  attr :version, :any, required: true
  attr :organization, :any, required: true

  defp feed_aside(assigns) do
    ~H"""
    <aside
      id="import-aside"
      aria-label="About importing a feed"
      class="grid w-full shrink-0 gap-4 lg:w-[23rem]"
    >
      <div class="rounded-card border border-subtle bg-canvas p-5">
        <h2 class="text-[15px] font-bold leading-snug text-strong">How importing works</h2>
        <ol class="mb-0 mt-3 grid list-none gap-3 p-0 text-sm">
          <.aside_step step={1} title="We read every file">
            Files this import doesn’t use are skipped.
          </.aside_step>
          <.aside_step step={2} title="A new version is created">
            {version_display_name(@version)} is never changed by an import.
          </.aside_step>
          <.aside_step step={3} title="It publishes when it’s done">
            The new version then appears in the version menu.
          </.aside_step>
        </ol>
        <p class="mb-0 mt-4 border-t border-subtle pt-3 text-[13px] text-default">
          <strong class="font-semibold text-strong">If anything fails, nothing is published.</strong>
          The attempt is listed under Unfinished imports, where you can delete it and try again. You can leave this page while an import runs.
        </p>
      </div>

      <details class="rounded-card border border-subtle px-5 py-1">
        <summary class="flex min-h-11 cursor-pointer items-center text-sm font-semibold text-strong">
          What’s in a complete feed?
        </summary>
        <ul class="mb-3 mt-0 grid list-none gap-2 p-0 text-[13px] text-default">
          <li>
            <strong class="font-semibold text-strong">Agency</strong>
            · who runs the service, and its timezone <span class="text-muted">(agency.txt)</span>
          </li>
          <li>
            <strong class="font-semibold text-strong">Routes</strong>
            <span class="text-muted">(routes.txt)</span>
          </li>
          <li>
            <strong class="font-semibold text-strong">Trips and stop times</strong>
            · the schedule <span class="text-muted">(trips.txt, stop_times.txt)</span>
          </li>
          <li>
            <strong class="font-semibold text-strong">Stops and stations</strong>
            <span class="text-muted">(stops.txt)</span>
          </li>
          <li>
            <strong class="font-semibold text-strong">Service days</strong>
            and exceptions <span class="text-muted">(calendar.txt, calendar_dates.txt)</span>
          </li>
          <li class="text-muted">
            Shapes, fares, transfers, levels and pathways are optional. We import whichever files are in your zip.
          </li>
        </ul>
      </details>

      <div :if={tods_pointer?(@organization)} class="rounded-card border border-subtle p-5">
        <h2 class="text-[15px] font-bold leading-snug text-strong">
          Importing garages or vehicles?
        </h2>
        <p class="mb-0 mt-2 text-sm text-default">
          Those come from a TODS file. Import them on
          <.text_link navigate={~p"/gtfs/#{@version.id}/settings/fleet"} label="Fleet" /> or
          <.text_link navigate={~p"/gtfs/#{@version.id}/settings/garages"} label="Garages" />, where you can review each row first.
        </p>
      </div>
    </aside>
    """
  end

  defp tods_pointer?(organization),
    do:
      ProductSurfaces.visible?(organization, :fleet) and
        ProductSurfaces.visible?(organization, :garages)

  defp skipped_title([_one]), do: "1 file will be skipped"
  defp skipped_title(files), do: "#{length(files)} files will be skipped"

  defp creates_summary(form) do
    case destination_name(form) do
      nil -> "A new version. Name it below."
      name -> "A new version named “#{name}”"
    end
  end

  defp destination_name(form) do
    case form[:version_name].value do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> nil
    end
  end

  # Files that were refused are not read, so they are left out of what Import says
  # it will read.
  defp reads_summary(upload, skipped) do
    entries = Enum.filter(upload.entries, &(upload_errors(upload, &1) == []))
    {skip, read} = Enum.split_with(entries, &(&1.client_name in skipped))

    read_text =
      case read do
        [] -> "No GTFS files"
        [%{client_name: name, client_size: size}] -> "#{name} (#{format_bytes(size)})"
        many -> "#{length(many)} GTFS files (#{format_bytes(total_size(many))})"
      end

    case skip do
      [] -> read_text
      [_one] -> "#{read_text}. 1 file is skipped."
      many -> "#{read_text}. #{length(many)} files are skipped."
    end
  end

  defp total_size(entries), do: entries |> Enum.map(& &1.client_size) |> Enum.sum()

  # Progress bar value must stay in 0..100 when processed overshoots the total.
  defp progress_percent(_processed, total) when not is_integer(total) or total <= 0, do: 0
  defp progress_percent(processed, total), do: min(100, round(processed * 100 / total))

  # ── Station workflow ──────────────────────────────────────────────────────

  attr :form, :any, required: true
  attr :upload, :any, required: true
  attr :diff_step, :atom, required: true
  attr :blockers, :list, default: []
  attr :version, :any, required: true
  attr :hidden, :boolean, default: false

  defp station_form(assigns) do
    assigns = assign(assigns, :entries, assigns.upload.entries)

    ~H"""
    <.form
      for={@form}
      id="diff-upload-form"
      class="grid grid-cols-1 gap-5"
      phx-change="validate_diff"
      phx-submit="compute_diff"
      hidden={@hidden}
    >
      <.message
        id="diff-destination"
        kind="info"
        title={"Approved changes go into #{version_display_name(@version)}."}
      >
        This edits the version you’re viewing, not a new one. Nothing changes until you approve it.
      </.message>

      <.message
        :if={@blockers != [] and @diff_step == :upload}
        id="diff-blockers"
        kind="error"
        title="We can’t compare these files yet"
      >
        At least one file couldn’t be read. Fix the files below and choose them again.
        <ul class="m-0 mt-2 list-disc pl-5">
          <li :for={error <- @blockers}>{format_parse_error(error)}</li>
        </ul>
        <:action>
          <.button
            id="diff-choose-corrected-files"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="reset-diff"
          >
            Choose corrected files
          </.button>
        </:action>
      </.message>

      <.dropzone
        id="diff-upload"
        upload={@upload}
        label="Station data files"
        help="levels.txt, stops.txt, pathways.txt, or one .zip. Up to 3 files, 50 MB each."
        action="Choose station files"
        hint="or drag them here"
        cancel_event="cancel-diff-upload"
      />

      <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
        <.button
          id="diff-compute-btn"
          type="submit"
          class="min-h-11"
          disabled={@entries == [] || @diff_step != :upload}
          data-unavailable={@entries == []}
        >
          Review changes
        </.button>
        <p id="diff-compute-reason" class="m-0 text-[13px] text-muted">
          {if @entries == [],
            do: "Choose at least one station file.",
            else: "Nothing is applied yet. You’ll review every change first."}
        </p>
      </div>
    </.form>
    """
  end

  # The prepared suggestion, shown for a person to decide. Reviewing it writes
  # nothing: the two actions are an explicit Confirm, which reaches the native
  # writer, and a Cancel, which does not. Nothing here claims a change was
  # applied - confirming only approves, and Apply stays a separate step.
  attr :suggestion, :any, required: true
  attr :error, :string, default: nil
  attr :status, :any, default: nil

  defp station_suggestion_review(assigns) do
    ~H"""
    <div
      :if={@status != nil}
      id="station-suggestion-status"
      role="status"
      tabindex="-1"
      class="border-t border-subtle px-5 py-4"
    >
      <p class="m-0 text-sm font-semibold text-strong">{@status.title}</p>
      <p class="m-0 mt-1 text-[13px] text-default">{@status.message}</p>
    </div>

    <div
      :if={@suggestion != nil}
      id="station-suggestion-review"
      class="border-t border-subtle bg-canvas px-5 py-4"
    >
      <h3 class="m-0 text-sm font-bold text-strong">Suggested decisions to review</h3>
      <p class="m-0 mt-1 max-w-[70ch] text-[13px] text-muted">
        The helper prepared these from the measurements you captured. Confirming approves them
        with the measurement each one was reviewed against; nothing is applied until you choose
        Apply changes.
      </p>

      <div
        :if={@error}
        id="station-suggestion-error"
        role="alert"
        tabindex="-1"
        class="mt-3 rounded-control border border-error/40 bg-error/5 px-4 py-3 text-[13px] text-error-fg"
      >
        <p class="m-0 font-semibold">Nothing was approved</p>
        <p class="m-0 mt-1">{@error}</p>
      </div>

      <ol
        id="station-suggestion-rows"
        class="m-0 mt-3 list-none divide-y divide-subtle border-y border-subtle p-0"
      >
        <li
          :for={row <- @suggestion.rows}
          id={"station-suggestion-row-#{row.decision_id |> String.replace(":", "-")}"}
          data-suggestion-row
          data-decision-id={row.decision_id}
          class="grid gap-x-5 gap-y-1 py-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]"
        >
          <div class="min-w-0">
            <p class="m-0 text-sm font-semibold text-strong">{row.subject}</p>
            <p class="m-0 mt-0.5 font-mono text-[13px] break-words text-default">
              {row.decision_id}
            </p>
            <p class="m-0 mt-1 text-[13px] text-default">
              <span class="text-muted">{row.current_width}</span>
              <span aria-hidden="true">→</span>
              <span class="font-semibold text-strong">{row.uploaded_width}</span>
              <span class="text-muted"> m</span>
            </p>
          </div>
          <div class="min-w-0">
            <p class="m-0 text-[13px] text-muted">Captured source</p>
            <p class="m-0 mt-1 text-[13px] text-default">{row.captured_source}</p>
          </div>
        </li>
      </ol>

      <div class="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2">
        <.button
          id="station-suggestion-confirm"
          type="button"
          class="min-h-11"
          phx-click="station-suggestion-confirm"
        >
          Confirm decisions
        </.button>
        <.button
          id="station-suggestion-cancel"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="station-suggestion-cancel"
        >
          Cancel
        </.button>
        <p class="m-0 text-[13px] text-muted">
          Confirming approves {length(@suggestion.rows)} {Wording.noun(
            length(@suggestion.rows),
            "change",
            "changes"
          )}. It applies nothing.
        </p>
      </div>
    </div>
    """
  end

  defp approved_scope_note(0, _reviewed, _total),
    do: "No change is approved, so Apply would do nothing."

  defp approved_scope_note(count, reviewed, total) do
    "Apply will make all #{count} approved #{Wording.noun(count, "change", "changes")} of #{total} in " <>
      "this review, including #{MapSet.size(reviewed)} confirmed against a captured " <>
      "measurement#{Wording.noun(MapSet.size(reviewed), "", "s")} and the rest approved natively."
  end

  # Which of this run's decisions carry captured provenance. Read from the
  # persisted manifest rather than from the conversation, so a reload or a helper
  # restart still tells an approved row apart from a measured one (INV-1).
  defp reviewed_decision_ids(run), do: run |> ChangeRuns.reviewed_evidence() |> reviewed_id_set()

  defp reviewed_id_set(entries) do
    MapSet.new(entries, & &1["decision_id"])
  end

  attr :step, :atom, required: true
  attr :run, :any, default: nil
  attr :summary, :map, required: true
  attr :blockers, :list, default: []
  attr :filter, :atom, required: true
  attr :decisions, :map, required: true
  attr :dependents, :map, default: %{}
  attr :parse_failures, :list, default: []
  attr :preview_count, :integer, default: 0
  attr :decisions_stream, :any, required: true
  attr :previews_stream, :any, required: true
  attr :observation_stations, :list, default: []
  attr :observation_station, :any, default: nil
  attr :observation_scope_form, Phoenix.HTML.Form, required: true
  attr :observation_form, Phoenix.HTML.Form, required: true
  attr :observation_pathways, :list, default: []
  attr :observation_journal_entries, :list, default: []
  attr :observation_captures, :map, default: %{}
  attr :observation_error, :string, default: nil
  attr :observation_notice, :string, default: nil
  attr :observation_helper_notice, :string, default: nil
  attr :agent_open?, :boolean, default: false
  attr :version, :any, required: true
  attr :evolution_targets, :map, default: %{}
  attr :station_suggestion, :any, default: nil
  attr :station_suggestion_error, :string, default: nil
  attr :station_suggestion_status, :any, default: nil

  defp station_panel(%{step: :review} = assigns) do
    approved = approved_decisions(assigns.decisions)

    assigns =
      assigns
      |> assign(:approved, approved)
      |> assign(:approved_count, length(approved))
      |> assign(:total, map_size(assigns.decisions))
      |> assign(:consequence, consequence(approved))
      |> assign(
        :reviewed_ids,
        # History is kept after a rejection, so only rows that are approved now
        # count as confirmed against a measurement.
        MapSet.intersection(
          reviewed_decision_ids(assigns.run),
          MapSet.new(approved, & &1.decision_id)
        )
      )
      |> assign(:bulk, bulk_actions(assigns.filter, assigns.summary, assigns.decisions))

    ~H"""
    <.card
      id="diff-review"
      title={"Review changes to #{version_display_name(@version)}"}
      subtitle="Nothing is applied until you select Apply."
    >
      <:badge>
        <div class="flex flex-wrap items-center gap-3">
          <.tone_badge class="whitespace-nowrap" tone="warning" icon="hero-clock">
            Nothing applied yet
          </.tone_badge>
          <.button
            id="diff-reset-btn"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="reset-diff"
          >
            Start over
          </.button>
        </div>
      </:badge>

      <div
        :if={@parse_failures != []}
        id="diff-degraded-region"
        role="status"
        class="border-b border-subtle px-5 py-4"
      >
        <.message kind="error" title="Some rows can’t be applied">
          A file was only partly readable. Its rows are shown as a read-only preview below. Everything else can be reviewed as normal.
          <ul class="m-0 mt-2 list-disc pl-5">
            <li :for={diagnostic <- @parse_failures}>{format_diagnostic(diagnostic)}</li>
          </ul>
          <:action>
            <.button
              id="diff-degraded-choose-corrected-files"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click="reset-diff"
            >
              Choose corrected files
            </.button>
          </:action>
        </.message>
      </div>

      <div :if={ignored_evolution_files(@run) > 0} class="border-b border-subtle px-5 py-4">
        <.ignored_closures_notice />
      </div>

      <div class="border-b border-subtle px-5 py-5">
        <.figures
          id="diff-summary"
          items={
            for action <- [:add, :modify, :conflict, :remove] do
              {"diff-summary-#{action}", action_label(action), Map.get(@summary, action, 0)}
            end
          }
        />
      </div>

      <div class="flex flex-wrap items-end justify-between gap-x-4 border-b border-subtle px-5">
        <div role="group" aria-label="Filter changes" class="-mb-px flex flex-wrap gap-x-1">
          <button
            :for={{filter, label, count} <- filter_tabs(@summary)}
            type="button"
            id={"diff-filter-#{filter}"}
            aria-pressed={to_string(@filter == filter)}
            class={[
              "min-h-11 border-b-[3px] border-transparent px-3 text-sm font-semibold text-muted hover:text-strong",
              "aria-pressed:border-action aria-pressed:text-action",
              "focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-focus"
            ]}
            phx-click="diff-filter"
            phx-value-filter={filter}
          >
            {label} <span class="ml-1 tabular-nums">{count}</span>
          </button>
        </div>
        <div id="diff-bulk" class="flex flex-wrap gap-2 py-2">
          <%= for {action, count, pending} <- @bulk do %>
            <button
              id={"diff-approve-all-#{action}"}
              type="button"
              class="inline-flex min-h-11 items-center justify-center rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas disabled:cursor-not-allowed disabled:bg-canvas disabled:text-muted"
              phx-click="approve-all"
              phx-value-action={action}
              disabled={pending == 0}
            >
              {if pending == 0,
                do: "All #{action_plural(action)} approved",
                else: "Approve all #{count} #{action_plural(action)}"}
            </button>
          <% end %>
        </div>
      </div>

      <p
        :if={filter_note(@filter)}
        id="diff-filter-note"
        class="m-0 border-b border-subtle bg-canvas px-5 py-3 text-[13px] text-muted"
      >
        {filter_note(@filter)}
      </p>

      <ol
        id="diff-decisions"
        phx-update="stream"
        class="m-0 list-none divide-y divide-subtle p-0"
      >
        <li
          id="diff-decisions-empty"
          class="hidden px-5 py-8 text-center text-sm text-muted only:block"
        >
          No changes match this filter.
        </li>
        <.review_row
          :for={{dom_id, decision} <- @decisions_stream}
          id={dom_id}
          decision={decision}
          dependents_note={dependents_note(@dependents, decision)}
        />
      </ol>

      <div
        :if={@preview_count != 0}
        id="diff-preview-region"
        class="border-t border-subtle bg-canvas px-5 py-4"
      >
        <h3 class="m-0 text-sm font-bold text-strong">Read-only preview</h3>
        <p class="m-0 mt-1 text-[13px] text-muted">
          These rows come from the incomplete file. They show what the file seems to say and can’t be approved.
        </p>
        <ol
          id="diff-preview-decisions"
          phx-update="stream"
          class="m-0 mt-2 list-none divide-y divide-subtle p-0"
        >
          <.review_row
            :for={{dom_id, decision} <- @previews_stream}
            id={dom_id}
            decision={decision}
          />
        </ol>
      </div>

      <.station_suggestion_review
        suggestion={@station_suggestion}
        error={@station_suggestion_error}
        status={@station_suggestion_status}
      />

      <div
        id="station-approved-apply-scope"
        tabindex="-1"
        class="border-t border-subtle px-5 py-4 focus:outline-none"
      >
        <h3 class="m-0 text-sm font-bold text-strong">Approved changes Apply will make</h3>
        <p class="m-0 mt-1 text-[13px] text-muted">
          {approved_scope_note(@approved_count, @reviewed_ids, @total)}
        </p>
        <ol
          :if={@approved != []}
          id="station-approved-apply-scope-list"
          class="m-0 mt-3 list-none divide-y divide-subtle p-0"
        >
          <li
            :for={decision <- @approved}
            id={"station-approved-row-#{decision.id}"}
            data-apply-scope-row
            data-reviewed={to_string(MapSet.member?(@reviewed_ids, decision.decision_id))}
            class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 py-2 text-[13px]"
          >
            <span class="min-w-0 font-semibold text-default">
              {decision.entity_type} <span class="font-mono">{decision.natural_key}</span>
            </span>
            <span class="text-muted">
              {if MapSet.member?(@reviewed_ids, decision.decision_id),
                do: "confirmed against a captured measurement",
                else: "approved natively"}
            </span>
          </li>
        </ol>
        <p :if={@approved == []} class="m-0 mt-3 text-[13px] text-muted">
          Nothing is approved, so Apply would do nothing.
        </p>
      </div>

      <%!-- The apply bar stays in view while a long list scrolls, and names the two
           costs the approvals include: removals and replaced edits. --%>
      <div class="sticky bottom-0 z-10 border-t border-subtle bg-white px-5 py-4 shadow-[0_-8px_24px_#0a13300d]">
        <p
          :if={@consequence}
          id="diff-consequence"
          class="m-0 mb-3 flex items-start gap-1.5 text-[13px] font-semibold text-warning-fg"
        >
          <.icon name="hero-exclamation-triangle" class="mt-px size-4 shrink-0" />
          <span>{@consequence}</span>
        </p>
        <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
          <.button
            id="diff-apply-btn"
            type="button"
            class="min-h-11"
            phx-click="apply-decisions"
            disabled={@approved_count == 0}
            data-unavailable={@approved_count == 0}
          >
            {apply_label(@approved_count)}
          </.button>
          <p id="diff-review-summary" aria-live="polite" class="m-0 text-[13px] text-muted">
            {if @approved_count == 0,
              do: "Approve at least one change to apply.",
              else:
                "#{@approved_count} of #{@total} changes approved. Nothing is applied until you select Apply."}
          </p>
        </div>
      </div>
    </.card>
    """
  end

  # A review that is running: comparing the files, or applying what was approved.
  defp station_panel(%{step: :processing, run: %ChangeRun{state: state}} = assigns)
       when state in [:pending_compute, :computing, :pending_apply, :applying] do
    assigns = assign(assigns, :state, state)

    ~H"""
    <.card
      id="diff-run-state"
      data-state={@state}
      title={progress_title(@state, @version)}
      subtitle={progress_subtitle(@state, @version)}
    >
      <:badge>
        <.tone_badge class="whitespace-nowrap" tone="info" icon="hero-arrow-path" spin>
          In progress
        </.tone_badge>
      </:badge>
      <div class="grid grid-cols-1 gap-5 px-5 py-5" role="status">
        <p class="m-0 text-sm text-default">{progress_body(@state)}</p>
        <div>
          <.button
            id="diff-cancel-btn"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="cancel-diff-run"
          >
            Cancel review
          </.button>
        </div>
      </div>
    </.card>
    """
  end

  # A review that stopped: partly applied, failed, interrupted, cancelled or
  # expired. What was applied is kept, and Retry is the one primary.
  defp station_panel(%{step: :processing, run: %ChangeRun{state: state} = run} = assigns) do
    applied = run_count(run, "applied")
    failed = run_count(run, "failed")
    unapplied = run_count(run, "unapplied")

    {title, tone, icon_name, word} = stopped_badge(state)

    assigns =
      assigns
      |> assign(:state, state)
      |> assign(:title, title)
      |> assign(:tone, tone)
      |> assign(:icon_name, icon_name)
      |> assign(:word, word)
      |> assign(:body, stopped_body(state, applied, failed, unapplied, assigns.version))
      |> assign(:applied, applied)
      |> assign(:failed, failed)
      |> assign(:unapplied, unapplied)
      |> assign(:counts?, state in [:partial, :failed, :interrupted])
      |> assign(:outcome, apply_outcome(assigns.decisions, assigns.run))
      |> assign(:retry_label, retry_label(state, failed + unapplied))
      |> assign(:start_over_label, start_over_label(state))

    ~H"""
    <.card
      id="diff-run-state"
      data-state={@state}
      title={@title}
      subtitle={"Station changes for #{version_display_name(@version)}"}
    >
      <:badge>
        <.tone_badge class="whitespace-nowrap" tone={@tone} icon={@icon_name}>{@word}</.tone_badge>
      </:badge>
      <div class="grid grid-cols-1 gap-5 px-5 py-5" role="status">
        <p class="m-0 text-sm text-default">{@body}</p>

        <.ignored_closures_notice :if={ignored_evolution_files(@run) > 0} />

        <.figures
          :if={@counts?}
          id="diff-run-counts"
          class="max-w-xl grid-cols-3"
          items={[
            {"diff-count-applied", "Applied", @applied},
            {"diff-count-failed", "Failed", @failed},
            {"diff-count-unapplied", "Not tried", @unapplied}
          ]}
        />

        <p :if={@state == :partial} id="diff-partial-note" class="m-0 text-[13px] text-muted">
          Applied changes stay in this version. Start over to review the remaining differences against the current data.
        </p>

        <.apply_outcome_list :if={@state == :partial} outcome={@outcome} />

        <.failed_decisions_list
          :if={@state in [:partial, :failed, :interrupted]}
          decisions={failed_decisions(@decisions)}
          targets={@evolution_targets}
          version_id={@version.id}
        />

        <.message :if={@blockers != []} id="diff-blockers" kind="error" title="What stopped it">
          <ul class="m-0 list-disc pl-5">
            <li :for={error <- @blockers}>{format_parse_error(error)}</li>
          </ul>
        </.message>

        <div class="flex flex-wrap items-center gap-3">
          <.button
            id="diff-retry-btn"
            type="button"
            class="min-h-11"
            phx-click="retry-diff-run"
          >
            {@retry_label}
          </.button>
          <.button
            id="diff-start-over-btn"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click="start-over-diff"
          >
            {@start_over_label}
          </.button>
        </div>
        <p
          :if={pathway_in_use?(@decisions)}
          id="diff-retry-hint"
          class="m-0 text-[13px] text-muted"
        >
          After the closures are deleted, Retry applies the failed removal again.
        </p>
        <p class="m-0 text-[13px] text-muted">
          This review is saved. You can leave this page and retry later.
        </p>
      </div>
    </.card>
    """
  end

  defp station_panel(%{step: :done} = assigns) do
    applied = run_count(assigns.run, "applied")
    failed = run_count(assigns.run, "failed")
    unapplied = run_count(assigns.run, "unapplied")
    outcome = apply_outcome(assigns.decisions, assigns.run)

    assigns =
      assigns
      |> assign(:applied, applied)
      |> assign(:failed, failed)
      |> assign(:unapplied, unapplied)
      |> assign(:outcome, outcome)

    ~H"""
    <section
      id="diff-done"
      aria-labelledby="diff-done-title"
      role="status"
      class="overflow-clip rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-start justify-between gap-x-6 gap-y-4 border-b border-subtle px-5 py-5">
        <div class="flex min-w-0 items-start gap-3">
          <span class="mt-0.5 grid size-8 shrink-0 place-items-center rounded-full bg-success-bg text-success-fg">
            <.icon name="hero-check" class="size-4" />
          </span>
          <div class="min-w-0">
            <h2
              id="diff-done-title"
              class="font-display text-[24px] font-semibold leading-tight tracking-[-0.025em] text-strong"
            >
              {@applied} {if @applied == 1, do: "change", else: "changes"} applied
            </h2>
            <p class="mt-1.5 text-sm text-default">
              They’re now part of {version_display_name(@version)}.<span :if={
                @failed == 0 and @unapplied == 0
              }> Nothing was left unapplied.</span>
            </p>
          </div>
        </div>
        <.button
          id="diff-open-stops"
          navigate={~p"/gtfs/#{@version.id}/stops"}
          class="min-h-11"
        >
          Open stops &amp; stations
        </.button>
      </div>
      <div class="grid gap-5 px-5 py-5">
        <.ignored_closures_notice :if={ignored_evolution_files(@run) > 0} />
        <.figures
          id="diff-run-counts"
          class="max-w-xl grid-cols-3"
          items={[
            {"diff-count-applied", "Applied", @applied},
            {"diff-count-failed", "Failed", @failed},
            {"diff-count-unapplied", "Not tried", @unapplied}
          ]}
        />

        <.apply_outcome_list outcome={@outcome} />
      </div>
      <div class="border-t border-subtle bg-canvas px-5 py-3">
        <.button
          id="diff-reset-btn"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="reset-diff"
        >
          Review more files
        </.button>
      </div>
    </section>
    """
  end

  attr :outcome, :list, required: true

  defp apply_outcome_list(assigns) do
    ~H"""
    <%!-- What the worker actually did, told apart from what was approved before
     it ran. A row confirmed against a captured measurement is named as
     such, an approval that predates it is named separately, and the
     actual applied/failed/stale outcome of each row is its own fact
     rather than a claim this page remembers (INV-1). --%>
    <div
      :if={@outcome != []}
      id="station-apply-outcome"
      class="max-w-2xl border-t border-subtle pt-4"
    >
      <h3 class="m-0 text-sm font-bold text-strong">What each approved change did</h3>
      <ol class="m-0 mt-3 list-none divide-y divide-subtle p-0">
        <li
          :for={row <- @outcome}
          id={"station-apply-outcome-row-#{row.decision.id}"}
          data-apply-outcome-row
          data-outcome={row.status}
          data-reviewed={to_string(row.reviewed?)}
          class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 py-2 text-[13px]"
        >
          <span class="min-w-0 font-semibold text-default">
            {row.decision.entity_type} <span class="font-mono">{row.decision.natural_key}</span>
          </span>
          <span class="text-muted">
            {outcome_sentence(row)}
          </span>
        </li>
      </ol>
    </div>
    """
  end

  # What the worker actually recorded for each decision that carried an approval,
  # read from the persisted decisions and the persisted provenance rather than
  # from anything this page kept in memory. An approved row that was never tried
  # is left out: it has no outcome to report yet.
  defp apply_outcome(decisions_by_id, run) do
    reviewed = reviewed_decision_ids(run)

    decisions_by_id
    |> Map.values()
    |> Enum.filter(&(&1.status in [:applied, :failed, :stale]))
    |> Enum.sort_by(& &1.decision_id)
    |> Enum.map(
      &%{decision: &1, status: &1.status, reviewed?: MapSet.member?(reviewed, &1.decision_id)}
    )
  end

  defp outcome_sentence(%{reviewed?: true, status: :applied}),
    do: "confirmed against a captured measurement · applied"

  defp outcome_sentence(%{reviewed?: true, status: :failed}),
    do: "confirmed against a captured measurement · failed"

  defp outcome_sentence(%{reviewed?: true, status: :stale}),
    do: "confirmed against a captured measurement · stale, nothing written"

  defp outcome_sentence(%{reviewed?: false, status: :applied}), do: "approved natively · applied"
  defp outcome_sentence(%{reviewed?: false, status: :failed}), do: "approved natively · failed"

  defp outcome_sentence(%{reviewed?: false, status: :stale}),
    do: "approved natively · stale, nothing written"

  # Capturing a measurement is native input, not a helper action: the person names
  # the exact pathway, what was measured and where it came from, and the server
  # checks it against the run before the helper can read it. Nothing here approves
  # or applies a change (INV-2).
  attr :stations, :list, required: true
  attr :station, :any, required: true
  attr :scope_form, Phoenix.HTML.Form, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :pathways, :list, required: true
  attr :journal_entries, :list, required: true
  attr :rows_stream, :any, required: true
  attr :captures, :map, required: true
  attr :error, :string, default: nil
  attr :notice, :string, default: nil
  attr :helper_notice, :string, default: nil
  attr :open?, :boolean, required: true

  defp station_observation_section(assigns) do
    ~H"""
    <div>
      <div class="flex flex-wrap items-start justify-between gap-3 px-5 pt-5">
        <div class="max-w-[62ch]">
          <p class="m-0 text-[13px] text-muted">
            The helper reads these widths to prepare a review of the changes they support.
          </p>
        </div>
        <.button
          id="station-helper-open"
          type="button"
          variant="secondary"
          phx-click="agent_open"
          aria-expanded={to_string(@open?)}
          aria-controls="agent-panel"
          class="min-h-11"
        >
          <.icon name="hero-sparkles" class="size-4" /> Open helper
        </.button>
      </div>

      <p id="station-helper-freshness" class="m-0 mt-3 text-[13px] text-muted">
        {@helper_notice}
      </p>

      <.form
        for={@scope_form}
        id="station-observation-scope-form"
        phx-change="station-observation-scope"
        class="mt-4 max-w-md px-5"
      >
        <.input
          field={@scope_form[:station_stop_id]}
          type="select"
          id="station-observation-scope-input"
          label="Station"
          prompt="Choose a station in this review"
          options={Enum.map(@stations, &{"#{&1.stop_name} (#{&1.stop_id})", &1.stop_id})}
          help="Only stations whose pathways this review changes can be measured."
        />
      </.form>

      <p
        :if={@notice}
        id="station-observation-notice"
        role="status"
        class="m-0 mt-3 px-5 text-[13px] text-default"
      >
        {@notice}
      </p>

      <div
        :if={@error}
        id="station-observation-error"
        role="alert"
        tabindex="-1"
        class="mx-5 mt-4 rounded-control border border-error/40 bg-error/5 px-4 py-3 text-[13px] text-error-fg focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
      >
        <p class="m-0 font-semibold">This measurement was not captured</p>
        <p class="m-0 mt-1">{@error}</p>
      </div>

      <div class="grid gap-6 px-5 pb-5 pt-5 lg:grid-cols-[minmax(0,22rem)_minmax(0,1fr)] lg:items-start">
        <div>
          <h3 class="m-0 text-sm font-bold text-strong">Add a measurement</h3>
          <p :if={@station == nil} class="m-0 mt-1 text-[13px] text-muted">
            Choose a station above to record a measurement.
          </p>
          <.form
            :if={@station != nil}
            for={@form}
            id="station-observation-form"
            phx-submit="station-observation-save"
            class="mt-3 grid grid-cols-1 gap-1"
          >
            <.input
              field={@form[:pathway_id]}
              type="select"
              id="station-observation-pathway"
              label="Pathway"
              prompt="Choose a pathway this review changes"
              options={Enum.map(@pathways, &{&1.label, &1.pathway_id})}
              help="Only the pathways this review changes for this station are listed."
            />
            <div class="grid grid-cols-1 gap-1 sm:grid-cols-2">
              <.input
                field={@form[:original_value]}
                type="text"
                id="station-observation-value"
                label="Measured value"
                inputmode="decimal"
                help="The number as it was written down, before conversion."
              />
              <.input
                field={@form[:unit]}
                type="select"
                id="station-observation-unit"
                label="Unit"
                options={observation_units()}
              />
            </div>
            <div class="grid grid-cols-1 gap-1 sm:grid-cols-2">
              <.input
                field={@form[:captured_date]}
                type="date"
                id="station-observation-date"
                label="Date captured"
              />
              <.input
                field={@form[:meaning]}
                type="select"
                id="station-observation-meaning"
                label="What it measures"
                prompt="Choose what was measured"
                options={observation_meanings()}
              />
            </div>
            <.input
              field={@form[:source_ref]}
              type="text"
              id="station-observation-source"
              label="Source reference"
              help="Where the measurement came from, e.g. a survey sheet reference."
            />
            <.input
              field={@form[:journal_entry_id]}
              type="select"
              id="station-observation-journal"
              label="Station note (optional)"
              prompt="No station note"
              options={Enum.map(@journal_entries, &{&1.label, &1.id})}
              help="Naming a note records its date and identity only. Read the note itself on the station page."
            />
            <div class="grid grid-cols-1 gap-1 sm:grid-cols-2">
              <.input
                field={@form[:accepted]}
                type="checkbox"
                id="station-observation-accepted"
                label="Staff accepted this measurement"
              />
              <.input
                field={@form[:conflict]}
                type="checkbox"
                id="station-observation-conflict"
                label="A conflict is recorded against it"
              />
            </div>
            <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-2">
              <.button
                id="station-observation-save"
                type="submit"
                class="min-h-11"
                disabled={@pathways == []}
                data-unavailable={@pathways == []}
              >
                Save measurement
              </.button>
              <p class="m-0 text-[13px] text-muted">
                Saving records the measurement against this run. It approves nothing.
              </p>
            </div>
          </.form>
        </div>

        <div class="min-w-0">
          <h3 class="m-0 text-sm font-bold text-strong">Captured for this station</h3>
          <ol
            id="station-observation-list"
            phx-update="stream"
            class="m-0 mt-3 list-none divide-y divide-subtle p-0"
          >
            <li
              id="station-observation-empty"
              class="hidden px-0 py-3 text-[13px] text-muted only:block"
            >
              No measurement is captured for this station yet. The helper summarizes the run until you
              capture one.
            </li>
            <li
              :for={{dom_id, {row, _position}} <- @rows_stream}
              id={dom_id}
              class="py-3"
            >
              <p class="m-0 text-sm font-semibold text-strong">
                {row["target"]["pathway_id"]} · {row["normalized_value"]} m
              </p>
              <p class="m-0 mt-0.5 text-[13px] text-muted">
                Measured {row["original_value"]} {row["unit"]} on {row["captured_date"]} as the minimum clear width
              </p>
              <p class="m-0 mt-0.5 text-[13px] text-muted">
                Source {row["source_ref"]}{if row["conflict"],
                  do: " · a conflict is recorded against this measurement"}
              </p>
            </li>
          </ol>

          <div
            :if={
              Enum.any?(@captures, fn {stop_id, _capture} ->
                stop_id != observation_station_stop(@station)
              end)
            }
            id="station-observation-captures"
            class="mt-4 pr-5"
          >
            <h4 class="m-0 text-[13px] font-bold uppercase tracking-wide text-muted">
              Measurements kept for other stations
            </h4>
            <ul class="m-0 mt-2 list-none space-y-1 p-0 text-[13px] text-muted">
              <li
                :for={{stop_id, capture} <- @captures}
                :if={capture.station.stop_id != observation_station_stop(@station)}
              >
                {capture.station.stop_name} ({stop_id}) · {observation_count(
                  length(capture.display_rows)
                )}
              </li>
            </ul>
            <p class="m-0 mt-1 text-[13px] text-muted">
              These stay out of the helper's context until you choose that station again.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp observation_units, do: @observation_units

  defp observation_meanings, do: @observation_meanings

  defp observation_station_stop(%Stop{stop_id: stop_id}), do: stop_id
  defp observation_station_stop(_station), do: nil

  attr :version, :any, required: true

  defp station_aside(assigns) do
    ~H"""
    <aside
      id="import-aside"
      aria-label="About station changes"
      class="grid w-full shrink-0 gap-4 lg:w-[23rem]"
    >
      <div class="rounded-card border border-subtle bg-canvas p-5">
        <h2 class="text-[15px] font-bold leading-snug text-strong">How station changes work</h2>
        <ol class="mb-0 mt-3 grid list-none gap-3 p-0 text-sm">
          <.aside_step step={1} title="We compare your files">
            with {version_display_name(@version)} and list every difference.
          </.aside_step>
          <.aside_step step={2} title="You approve or reject each one">
            Nothing is applied until you select Apply.
          </.aside_step>
          <.aside_step step={3} title="Approved changes are applied">
            to this version, after a last check that each record hasn’t changed since your review.
          </.aside_step>
        </ol>
      </div>
      <div class="rounded-card border border-subtle p-5">
        <h2 class="text-[15px] font-bold leading-snug text-strong">Read before approving</h2>
        <ul class="mb-0 mt-2 grid list-disc gap-2 pl-5 text-sm text-default">
          <li>
            <strong class="font-semibold text-strong">Removed</strong>
            means it’s in this version but not in your file. It stays unless you approve the removal.
          </li>
          <li>
            <strong class="font-semibold text-strong">Edited here</strong>
            means it was edited after it was created. Approving replaces those edits.
          </li>
        </ul>
      </div>
    </aside>
    """
  end

  defp approved_decisions(decisions_by_id),
    do: for({_id, decision} <- decisions_by_id, decision.status == :approved, do: decision)

  defp filter_tabs(summary) do
    [
      {:all, "All", decision_total(summary)},
      {:add, action_label(:add), summary.add},
      {:modify, action_label(:modify), summary.modify},
      {:conflict, action_label(:conflict), summary.conflict},
      {:remove, action_label(:remove), summary.remove}
    ]
  end

  # The bulk approvals on offer. The list of everything offers only the two safe
  # kinds; approving many removals or many replaced edits from a mixed list is
  # the costliest mistake in this workflow, so each of those is approved from its
  # own tab. Each entry is `{action, count, still_to_approve}`.
  defp bulk_actions(filter, summary, decisions) do
    actions = if filter == :all, do: [:add, :modify], else: [filter]

    for action <- actions, count = Map.get(summary, action, 0), count > 0 do
      pending =
        Enum.count(decisions, fn {_id, decision} ->
          decision.action == action and decision.status != :approved
        end)

      {action, count, pending}
    end
  end

  defp filter_note(:conflict),
    do:
      "These were edited after they were created. Approve them one at a time, or approve all if your file is the source of truth."

  defp filter_note(:remove),
    do: "These are in this version but not in your file. Approving deletes them from the version."

  defp filter_note(_filter), do: nil

  defp apply_label(0), do: "Apply changes"
  defp apply_label(1), do: "Apply 1 change"
  defp apply_label(count), do: "Apply #{count} changes"

  defp progress_title(:pending_compute, _version), do: "Saving your files"

  defp progress_title(:computing, version),
    do: "Comparing your files with #{version_display_name(version)}"

  defp progress_title(:pending_apply, _version), do: "Preparing approved changes"
  defp progress_title(:applying, _version), do: "Applying approved changes"

  defp progress_subtitle(state, version) when state in [:pending_apply, :applying],
    do: "Changes are going into #{version_display_name(version)}"

  defp progress_subtitle(_state, _version), do: "Nothing is applied yet."

  defp progress_body(state) when state in [:pending_compute, :computing],
    do: "This review is saved. You can leave this page and come back to it."

  defp progress_body(_state),
    do:
      "Each change is checked against the current version just before it’s applied. Changes already applied stay applied if you cancel. You can leave this page; the review is saved."

  defp stopped_badge(:partial),
    do: {"Some changes need attention", "warning", "hero-exclamation-triangle", "Partly applied"}

  defp stopped_badge(:failed),
    do: {"The review failed", "error", "hero-exclamation-triangle", "Failed"}

  defp stopped_badge(:interrupted),
    do: {"The review was interrupted", "error", "hero-exclamation-triangle", "Interrupted"}

  defp stopped_badge(:cancelled),
    do: {"The review was cancelled", "neutral", "hero-x-mark", "Cancelled"}

  defp stopped_badge(:expired), do: {"This review expired", "warning", "hero-clock", "Expired"}

  defp stopped_body(:partial, applied, failed, unapplied, version) do
    "#{applied} #{Wording.noun(applied, "change was", "changes were")} applied to #{version_display_name(version)}. #{failed} failed and #{unapplied} weren’t tried. Retry to apply the rest."
  end

  defp stopped_body(:failed, 0, _failed, _unapplied, _version),
    do: "The review stopped before it could finish, so nothing was applied."

  defp stopped_body(:failed, applied, _failed, _unapplied, _version),
    do:
      "The review stopped after #{applied} #{Wording.noun(applied, "change was", "changes were")} applied."

  defp stopped_body(:interrupted, applied, _failed, _unapplied, _version) do
    "The review stopped unexpectedly. #{if applied > 0, do: "#{applied} #{Wording.noun(applied, "change was", "changes were")} applied. "}Your files are saved, so you can retry."
  end

  defp stopped_body(:cancelled, _applied, _failed, _unapplied, _version),
    do:
      "You cancelled this review. Nothing further was applied. Your files are saved, so you can still retry."

  defp stopped_body(:expired, _applied, _failed, _unapplied, _version),
    do:
      "This review was built by an older version of the app and can’t be applied. Retry to compare your files again."

  defp retry_label(:partial, remaining) when remaining > 0,
    do: "Retry #{remaining} #{Wording.noun(remaining, "change", "changes")}"

  defp retry_label(_state, _remaining), do: "Retry review"

  defp start_over_label(state) when state in [:failed, :cancelled, :expired],
    do: "Choose corrected files"

  defp start_over_label(_state), do: "Start over"

  defp run_count(%ChangeRun{summary: summary}, key) when is_map(summary),
    do: Map.get(summary, key, 0)

  defp run_count(_run, _key), do: 0

  # Create exactly one staging target + pending run, subscribe to its stable
  # topic, and ask the supervised Runner to take the run. The Runner is admitted
  # and claims the run before a single upload byte is read, then waits while this
  # process copies the uploads into the run's private directory and installs them.
  # The route/current version is never a write destination, and no task reference
  # is owned by the socket: the Runner is durable and survives disconnect once the
  # source is installed (AC-6). The run exists before any file is staged, so the
  # orphan sweep never sees a staged directory without its run.
  defp create_and_start_import(socket, _form_data, version_name) do
    organization_id = socket.assigns.current_organization.id
    actor = %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}

    case ImportRuns.create_pending_target(organization_id, actor, %{name: version_name}) do
      {:error, :forbidden} ->
        # Nothing was created. The form and the chosen files stay as they are.
        {:noreply, put_flash(socket, :error, @permission_error)}

      {:error, changeset} ->
        # Pre-consumption changeset error (blank/duplicate name): return to the
        # form, preserve every upload entry, focus/announce the error,
        # and start no runner. No lifecycle row was created.
        socket =
          socket
          |> assign(:version_name_touched, true)
          |> assign(
            :form,
            to_form(%{"version_name" => version_name},
              as: :gtfs_import_form,
              errors: changeset_errors(changeset, version_name)
            )
          )
          |> assign(:import_result, nil)
          |> assign(:import_agency_health, nil)
          |> assign(:import_left_out, [])

        socket = push_event(socket, "focus_first_error", %{selector: "#gtfs-import-version-name"})

        {:noreply, socket}

      {:ok, %{run: run, version: target}} ->
        # Subscribe to the stable topic BEFORE starting the runner so no
        # broadcast is missed.
        Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ImportRuns.topic(run.id))

        case Runner.start_import(organization_id, run.id, run.lease_token, caller: self()) do
          {:ok, runner} ->
            stage_and_install_source(socket, runner, run, target)

          {:error, :busy} ->
            refuse_unstarted_import(socket, run, version_name)

          {:error, _claim_failure} ->
            # No runner owns the run, so the staging target is closed here.
            failed = fail_target_best_effort(run, target)
            Phoenix.PubSub.unsubscribe(GtfsPlanner.PubSub, ImportRuns.topic(run.id))

            {:noreply,
             socket
             |> assign(:import_target, failed)
             |> assign(:import_result, {:error, failed, :import_not_started})}
        end
    end
  end

  # The runner supervisor is full. Nothing was staged, and the uploads are still in
  # the form, so the same Import click works once the other import finishes.
  defp refuse_unstarted_import(socket, run, version_name) do
    organization_id = socket.assigns.current_organization.id

    _ = ImportRuns.fail_unstarted(organization_id, run.id, run.lease_token)
    Phoenix.PubSub.unsubscribe(GtfsPlanner.PubSub, ImportRuns.topic(run.id))

    {:noreply,
     socket
     |> assign(:form, to_form(%{"version_name" => version_name}, as: :gtfs_import_form))
     |> put_flash(:error, @import_busy_message)}
  end

  # Stages the uploads and hands their descriptors to the runner that is waiting for
  # them. The runner executes publication through ImportRuns, broadcasting
  # {:import_run_changed, run.id} on closure.
  defp stage_and_install_source(socket, runner, run, target) do
    organization_id = socket.assigns.current_organization.id

    case stage_import_files(socket, organization_id, run.id) do
      {:ok, staged_files} ->
        case Runner.install_source(runner, staged_files) do
          :ok ->
            drop_import_files(socket)

            {:noreply,
             socket
             |> assign(:import_target, target)
             |> assign(:importing, true)
             |> assign(:import_result, nil)
             |> assign(:import_agency_health, nil)
             |> assign(:import_left_out, [])
             |> assign(:published_version, nil)
             |> assign(:import_progress, nil)}

          {:error, _stopped} ->
            # The runner passed its install deadline and closed the run while the
            # copy was still running. `stage/4` may have recreated the directory
            # after the runner removed it, so remove it again.
            _ = SourceStorage.remove(organization_id, run.id)
            source_refused(socket, target, :source_not_installed)
        end

      {:error, reason} ->
        # Post-create staging error: the runner closes the run as `source_not_installed`,
        # deletes the empty staging version and removes whatever was written. No worker
        # starts, and the same name can be submitted again.
        _ = Runner.cancel_source(runner)
        source_refused(socket, target, reason)
    end
  end

  # A set that is over the storage limit stays selected so the person can remove
  # files from it. After any other refusal the person chooses the files again.
  defp source_refused(socket, target, reason) do
    if reason != :artifact_capacity_exceeded, do: drop_import_files(socket)

    {:noreply,
     socket
     |> assign(:import_result, {:error, target, {:upload_consumption_failed, reason}})
     |> assign(:importing, false)
     |> assign(:import_progress, nil)}
  end

  # Copies the uploads from their temporary paths into the run's private directory
  # without reading them into memory, and leaves the entries in the upload so a
  # start that is refused keeps the chosen files in the form. `drop_import_files/1`
  # removes them once the import no longer needs them. Staging takes the whole set
  # in one call so the size budgets and the all-or-nothing cleanup cover it.
  defp stage_import_files(socket, organization_id, run_id) do
    uploads =
      consume_uploaded_entries(socket, :gtfs_files, fn %{path: path}, entry ->
        {:postpone, %{path: path, filename: entry.client_name}}
      end)

    SourceStorage.stage(organization_id, run_id, uploads, max_run_bytes: @max_import_run_bytes)
  end

  defp drop_import_files(socket) do
    consume_uploaded_entries(socket, :gtfs_files, fn _meta, _entry -> {:ok, nil} end)
  end

  # Best-effort conditional closure of a still-unpublished target. A published
  # or failed target is left untouched (the transition is a no-op there).
  defp fail_target_best_effort(%Run{} = run, %GtfsVersion{} = target) do
    case ImportRuns.fail_pending_target(
           target.organization_id,
           run.id,
           run.lease_token,
           :upload_consumption_failed
         ) do
      {:ok, _run, failed} -> failed
      {:error, _reason} -> target
    end
  end

  defp discardable?(%Run{state: state}), do: state in @stopped_states

  # Event `run_id` values arrive as string UUIDs, matching the `:binary_id`
  # primary key's Elixir-side string representation. Validate and return the
  # string unchanged so downstream ImportRuns queries and stream lookups match.
  defp load_run_id(run_id) when is_binary(run_id) do
    case Ecto.UUID.cast(run_id) do
      {:ok, _} -> run_id
      :error -> nil
    end
  end

  defp find_recoverable_run(socket, run_id) do
    organization_id = socket.assigns.current_organization.id

    ImportRuns.list_recoverable(organization_id)
    |> Enum.find(&(&1.id == run_id))
  end

  # Reset every staged GTFS upload entry so a discarded target can be re-uploaded
  # cleanly under the same (prefilled) version name.
  defp reset_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.gtfs_files.entries, socket, fn entry, acc ->
      cancel_upload(acc, :gtfs_files, entry.ref)
    end)
  end

  # One short announce string per state so the single ARIA live region (AC-18)
  # reports a meaningful change exactly once per transition.
  defp recovery_announce_text(%Run{state: "pending"}), do: "Import pending"
  defp recovery_announce_text(%Run{state: "running"}), do: "Import running"
  defp recovery_announce_text(%Run{state: "partial"}), do: "Import partially committed"
  defp recovery_announce_text(%Run{state: "failed"}), do: "Import failed"
  defp recovery_announce_text(%Run{state: "interrupted"}), do: "Import interrupted"
  defp recovery_announce_text(%Run{state: "publication_failed"}), do: "Publication failed"
  defp recovery_announce_text(%Run{state: "cleaning"}), do: "Cleanup in progress"
  defp recovery_announce_text(%Run{state: "cleanup_failed"}), do: "Cleanup failed"
  defp recovery_announce_text(%Run{}), do: nil

  # The version name is edited under the form field `:version_name`, while the
  # schema validates the `:name` column. Remap so the inline error renders
  # against the field the user actually sees, and say what to do about it.
  defp changeset_errors(%Ecto.Changeset{} = changeset, name) do
    for {field, {message, _opts}} <- changeset.errors do
      {version_field(field), version_name_error(message, name)}
    end
  end

  defp version_field(:name), do: :version_name
  defp version_field(other), do: other

  defp version_name_error("can't be blank", _name), do: @name_required_message

  defp version_name_error(@name_taken_message, name),
    do: "You already have a version named “#{String.trim(name)}”. Choose a different name."

  defp version_name_error(message, _name), do: message

  defp target_name(%GtfsVersion{name: name}), do: name
  defp target_name(_), do: "the requested version"

  defp version_display_name(%GtfsVersion{name: name}), do: name
  defp version_display_name(%{name: name}) when is_binary(name), do: name
  defp version_display_name(_), do: "current"

  defp empty_diff_summary do
    %{add: 0, modify: 0, remove: 0, conflict: 0}
  end

  defp failed_decisions(decisions_by_id) do
    decisions_by_id
    |> Map.values()
    |> Enum.filter(&(&1.status in [:failed, :stale]))
    |> Enum.sort_by(& &1.decision_id)
  end

  defp decision_failure_reason(%{apply_failure_code: "pathway_in_use"}),
    do: "Not removed: this pathway has scheduled closures."

  defp decision_failure_reason(%{apply_failure_code: "drifted"}),
    do: "Changed since the review was computed"

  defp decision_failure_reason(%{apply_failure_code: "stale_reviewed_evidence"}),
    do: "No longer matches the accepted observation it was reviewed with"

  defp decision_failure_reason(%{apply_failure_code: "dependencies_unmet"}),
    do: "Depends on a change that was not applied"

  defp decision_failure_reason(%{apply_failure_code: "has_dependents", entity_type: :level}),
    do: "Still used by stops in this version"

  defp decision_failure_reason(%{apply_failure_code: "has_dependents"}),
    do: "Still used by trips, transfers, pathways or other records in this version"

  defp decision_failure_reason(_decision), do: "Could not be applied"

  # The failure row links to the station that owns the pathway. Stations come
  # from the same scoped endpoint-ancestry rule the closure usage links use, so a
  # pathway without a station ancestor keeps the explanation as text rather than
  # an invented owner. A run from before the closures existed has no failed rows.
  defp pathway_in_use_targets(organization_id, %ChangeRun{} = run, decisions) do
    failed =
      Enum.filter(decisions, fn decision ->
        decision.entity_type == :pathway and decision.apply_failure_code == "pathway_in_use"
      end)

    case failed do
      [] ->
        %{}

      failed ->
        stations =
          Gtfs.pathway_station_ids(
            organization_id,
            run.gtfs_version_id,
            Enum.map(failed, & &1.natural_key)
          )

        Map.new(failed, fn decision ->
          {decision.decision_id,
           named_stations(
             organization_id,
             run.gtfs_version_id,
             Map.get(stations, decision.natural_key, [])
           )}
        end)
    end
  end

  defp named_stations(_organization_id, _version_id, []), do: []

  defp named_stations(organization_id, version_id, stop_ids) do
    stop_ids
    |> Enum.map(&Gtfs.get_stop_by_stop_id(organization_id, version_id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&%{stop_id: &1.stop_id, stop_name: &1.stop_name})
  end

  defp evolutions_href(version_id, station_stop_id, pathway_id) do
    ~p"/gtfs/#{version_id}/stops/#{station_stop_id}/evolutions?#{%{"pathway" => pathway_id}}"
  end

  defp pathway_in_use?(decisions_by_id) do
    decisions_by_id |> Map.values() |> Enum.any?(&(&1.apply_failure_code == "pathway_in_use"))
  end

  defp dependents_note(dependents, decision) do
    case Map.fetch(dependents, {decision.entity_type, decision.natural_key}) do
      {:ok, kinds} -> dependents_sentence(kinds)
      :error -> nil
    end
  end

  defp dependents_sentence(kinds) do
    phrases =
      kinds
      |> Enum.sort()
      |> Enum.map(fn {kind, count} -> "#{count} #{dependent_noun(kind, count)}" end)

    "Used by #{to_sentence(phrases)}. Removal will be refused while they exist."
  end

  defp dependent_noun(:stop_times, count), do: ngettext("stop time", "stop times", count)
  defp dependent_noun(:transfers, count), do: ngettext("transfer", "transfers", count)
  defp dependent_noun(:pathways, count), do: ngettext("pathway", "pathways", count)
  defp dependent_noun(:child_stops, count), do: ngettext("child stop", "child stops", count)
  defp dependent_noun(:stop_areas, count), do: ngettext("stop area", "stop areas", count)

  defp dependent_noun(:route_pattern_stops, count),
    do: ngettext("route pattern stop", "route pattern stops", count)

  defp dependent_noun(:fare_leg_join_rules, count),
    do: ngettext("fare leg join rule", "fare leg join rules", count)

  defp dependent_noun(:stops, count), do: ngettext("stop", "stops", count)

  defp dependent_noun(:relief_points, count), do: ngettext("relief point", "relief points", count)

  defp dependent_noun(:flex_hubs, count),
    do: ngettext("flex hub service", "flex hub services", count)

  defp dependent_noun(:flex_first, count),
    do: ngettext("flex service first stop", "flex service first stops", count)

  defp dependent_noun(:flex_last, count),
    do: ngettext("flex service last stop", "flex service last stops", count)

  defp dependent_noun(:stop_levels, count), do: ngettext("level", "levels", count)

  defp dependent_noun(:journal_entries, count),
    do: ngettext("journal entry", "journal entries", count)

  defp dependent_noun(:editing_statuses, count),
    do: ngettext("editing status", "editing statuses", count)

  defp dependent_noun(:walkability_tests, count),
    do: ngettext("walkability test", "walkability tests", count)

  defp dependent_noun(:deadhead_from, count),
    do: ngettext("deadhead time from this stop", "deadhead times from this stop", count)

  defp dependent_noun(:deadhead_to, count),
    do: ngettext("deadhead time to this stop", "deadhead times to this stop", count)

  defp dependent_noun(:translations, count), do: ngettext("translation", "translations", count)

  defp dependent_noun(:segments_from, count),
    do: ngettext("map line section from", "map line sections from", count)

  defp dependent_noun(:segments_to, count),
    do: ngettext("map line section to", "map line sections to", count)

  defp to_sentence([phrase]), do: phrase

  defp to_sentence(phrases) do
    {leading, [last]} = Enum.split(phrases, -1)
    Enum.join(leading, ", ") <> " and " <> last
  end

  defp decision_total(summary) do
    (summary.add || 0) + (summary.modify || 0) + (summary.conflict || 0) + (summary.remove || 0)
  end

  # A parse problem as a sentence that says what to fix: the file leads when the
  # problem is in one file, and the row when it is in one row.
  defp format_parse_error(%ParseError{file: file, row: row, reason: reason})
       when is_binary(file) and is_integer(row),
       do: "#{file}, row #{row}: #{reason_phrase(reason)}."

  defp format_parse_error(%ParseError{file: file, reason: reason}) when is_binary(file),
    do: "#{file}: #{reason_phrase(reason)}."

  defp format_parse_error(%ParseError{reason: reason}), do: sentence(reason_phrase(reason))
  defp format_parse_error(%{reason: %ParseError{} = error}), do: format_parse_error(error)
  defp format_parse_error(%{reason: reason}), do: sentence(reason_phrase(reason))
  defp format_parse_error(_error), do: "The files couldn’t be compared."

  # A stored diagnostic carries a code and one detail, normally the file it is
  # about. A duplicate names the kind of data instead of a file.
  defp format_diagnostic(%{} = diagnostic) do
    code = Map.get(diagnostic, "code", Map.get(diagnostic, :code, "unexpected_parser_failure"))
    detail = Map.get(diagnostic, "detail", Map.get(diagnostic, :detail, ""))

    case {to_string(code), detail} do
      {"duplicate_entity_file", detail} when detail not in [nil, ""] ->
        "More than one #{detail}.txt was included."

      {code, detail} when detail not in [nil, ""] ->
        "#{detail}: #{reason_phrase(code)}."

      {code, _detail} ->
        sentence(reason_phrase(code))
    end
  end

  defp format_diagnostic(diagnostic), do: to_string(diagnostic)

  @reason_phrases %{
    empty_content: "the file is empty",
    invalid_utf8: "the file isn’t saved as UTF-8 text",
    blank_header: "a column name is blank",
    duplicate_header: "two columns have the same name",
    wrong_field_count: "it has more or fewer values than the header row",
    unterminated_quote: "a quoted value isn’t closed",
    malformed_quote: "a quoted value is malformed",
    forbidden_control_character: "it contains an invalid line break or tab",
    record_too_long: "a row is longer than 1,048,576 bytes",
    archive_unreadable: "the zip couldn’t be opened",
    archive_too_large: "the zip is too large once unpacked",
    nested_archive: "the zip contains another zip",
    duplicate_entity_file: "more than one file provides the same data",
    missing_natural_key_header: "the file is missing its ID column",
    duplicate_natural_key: "two rows use the same ID",
    blank_natural_key: "a row has no ID",
    semantic_row: "a row has a value that isn’t allowed",
    unexpected_parser_failure: "the file couldn’t be read",
    busy: "another change review is running"
  }

  defp reason_phrase(reason) when is_atom(reason),
    do: Map.get(@reason_phrases, reason, humanize(reason))

  defp reason_phrase(reason) when is_binary(reason) do
    Enum.find_value(@reason_phrases, humanize(reason), fn {atom, phrase} ->
      if Atom.to_string(atom) == reason, do: phrase
    end)
  end

  defp reason_phrase(_reason), do: "the files couldn’t be compared"

  defp humanize(value), do: value |> to_string() |> String.replace("_", " ")

  defp sentence(phrase) do
    {first, rest} = String.split_at(phrase, 1)
    String.upcase(first) <> rest <> "."
  end
end
